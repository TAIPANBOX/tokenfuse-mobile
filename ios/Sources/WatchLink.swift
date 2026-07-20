import Foundation
import Observation
import WatchConnectivity

/// The iPhone-to-Watch pairing handoff (itrat-console/13 D12, W4).
///
/// ## Why the watch does not scan anything
///
/// Apple Watch has no camera, so it cannot scan the desktop's pairing QR, and
/// watchOS has no CoreImage, so it cannot render one of its own for the phone
/// to scan back. Typing an 8-character code on a 40mm screen is not a serious
/// option either. So the phone, which already scanned the QR, forwards the
/// watch its own code over WatchConnectivity: one scan admits both devices.
///
/// ## What crosses the link, and what does not
///
/// Only the four values the watch needs to redeem its OWN slot: the relay URL,
/// the relay's SPKI pin, the watch's one-time code, and the org. The phone's
/// device token, the phone's signing key and the phone's own (already spent)
/// code never cross. The watch generates its own key and gets its own token
/// from the relay, which is what makes a kill from the wrist signed by the
/// wrist (`RelayPairingService.pair`).
///
/// The code is one-time and short-lived (the relay's armed window, not the
/// Cloud's longer TTL), and the channel is Apple's own encrypted pairing
/// transport between two devices the operator already owns. `transferUserInfo`
/// rather than `sendMessage`, so the handoff is queued and still arrives if the
/// watch app is asleep or out of range when the phone pairs.
enum WatchLinkPayload {
    /// Payload schema version. A watch running an older build ignores a
    /// version it does not know rather than half-reading it.
    static let version = 1

    static let versionKey = "v"
    static let relayKey = "relay"
    static let pinKey = "pin"
    static let codeKey = "code"
    static let orgKey = "org"
    static let expiresKey = "exp"

    /// Encodes a watch-slot intent for the wire. Returns `nil` for an intent
    /// that is not actually a watch intent, so the phone cannot ship its own
    /// slot across by mistake.
    ///
    /// `expiresUnix` is the relay's own armed-window expiry. It travels with
    /// the code for one reason: `transferUserInfo` parks its payload on disk
    /// in the system queue on BOTH devices until it is consumed, with no
    /// latency bound at all. Carrying the deadline means a payload that sat in
    /// that queue too long is inert when it finally lands, instead of being a
    /// live credential the watch cheerfully tries to spend.
    static func encode(_ intent: PairingIntent, expiresUnix: Int?) -> [String: Any]? {
        guard intent.kind == .watch else { return nil }
        var payload: [String: Any] = [
            versionKey: version,
            relayKey: intent.relayURL,
            pinKey: intent.pin,
            codeKey: intent.code,
            orgKey: intent.org,
        ]
        if let expiresUnix { payload[expiresKey] = expiresUnix }
        return payload
    }

    /// Decodes a received payload. Every field must be present and non-empty,
    /// the version must match, and the window must not already have closed, or
    /// this is `nil`: a partially understood or already-dead pairing is not
    /// something to attempt.
    static func decode(_ userInfo: [String: Any], now: Int = Int(Date().timeIntervalSince1970))
        -> PairingIntent?
    {
        guard let v = userInfo[versionKey] as? Int, v == version,
              let relay = userInfo[relayKey] as? String, !relay.isEmpty,
              let pin = userInfo[pinKey] as? String, !pin.isEmpty,
              let code = userInfo[codeKey] as? String, !code.isEmpty,
              let org = userInfo[orgKey] as? String, !org.isEmpty
        else { return nil }
        // An absent deadline means an older phone that did not send one; the
        // relay still enforces its own window, so this only loses the early
        // discard, never the actual protection.
        let expires = userInfo[expiresKey] as? Int
        if let expires, now >= expires { return nil }
        return PairingIntent(
            relayURL: relay, pin: pin, code: code, org: org, kind: .watch,
            codeWatch: nil, expiresUnix: expires)
    }
}

/// Where a received handoff lands, so SwiftUI can react to it. Main-actor
/// isolated because the views observing it are.
@MainActor
@Observable
final class WatchPairingInbox {
    static let shared = WatchPairingInbox()

    /// The most recent intent handed over by the phone, cleared once the watch
    /// has redeemed it (or decided it is already paired).
    var pending: PairingIntent?

    private init() {}
}

/// Owns the `WCSession` on both platforms. One instance, activated once at
/// launch; the delegate callbacks arrive off the main actor, so everything
/// user-visible hops back explicitly.
final class WatchLink: NSObject, @unchecked Sendable {
    static let shared = WatchLink()

    private override init() { super.init() }

    /// Activate the session if this device supports one. Safe to call more
    /// than once. A device with no counterpart (an iPad, or a simulator with
    /// no paired watch) simply never activates, and every send below turns
    /// into a no-op rather than an error the operator has to read.
    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Hand the watch its pairing intent. No-op when the QR carried no watch
    /// code, when this build has no session, or when no watch is paired to
    /// this phone: pairing a phone alone stays a perfectly good outcome.
    /// Returns whether the handoff was actually queued, so the caller can say
    /// something honest in the UI.
    @discardableResult
    func sendPairing(_ intent: PairingIntent, expiresUnix: Int? = nil) -> Bool {
        guard WCSession.isSupported(),
              let payload = WatchLinkPayload.encode(intent, expiresUnix: expiresUnix)
        else {
            return false
        }
        let session = WCSession.default
        #if os(iOS)
        // `isPaired` exists only on the phone side and is the honest check for
        // "is there a watch to hand this to at all".
        guard session.isPaired, session.isWatchAppInstalled else { return false }
        #endif
        guard session.activationState == .activated else { return false }
        session.transferUserInfo(payload)
        return true
    }
}

extension WatchLink: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            // Not fatal: the phone still pairs, the watch just will not be
            // handed anything until the link comes up.
            print("WatchLink: activation failed: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let intent = WatchLinkPayload.decode(userInfo) else { return }
        Task { @MainActor in
            // Publish unconditionally, even when a session already exists.
            //
            // This used to `guard SessionStore.load() == nil`, on the reasoning
            // that a one-time code has no business living in an observable when
            // there is nothing to do with it. That reasoning has a hole, and it
            // is the hole that made a disconnected watch unrecoverable: after an
            // admin disconnect the watch still HOLDS a session, it just does not
            // know the session is dead yet. The phone re-pairs, forwards the new
            // code, WatchConnectivity delivers it the moment the watch app next
            // wakes - typically before the first poll has come back 401 - and
            // this guard threw it away. `transferUserInfo` delivers once, so the
            // code was gone from the system queue for good, and the operator had
            // to go back to the desktop and scan a THIRD QR.
            //
            // Parking it instead is safe: `WatchRootView` still refuses to
            // redeem while a session is live (`account == nil` in its
            // `onChange`), so a healthy watch is never re-pointed by a handoff.
            // The intent simply waits for the revocation latch to clear the
            // session, and `PairingIntent.expiresUnix` is checked at redemption
            // so a code that timed out while parked is discarded rather than
            // presented.
            WatchPairingInbox.shared.pending = intent
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so a switch to a different watch keeps working.
        WCSession.default.activate()
    }
    #endif
}
