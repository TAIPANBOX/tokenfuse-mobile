import SwiftUI

/// Entry point: restore a paired session (own signing key) and show the
/// exception queue; otherwise wait for the iPhone to hand this watch its own
/// pairing code over WatchConnectivity (D12 W4).
///
/// The watch has no camera, so it never scans the desktop QR itself. The phone
/// scans once, pairs itself, and forwards the second code from the same QR.
/// This watch then redeems that code with its OWN key and gets its OWN token,
/// which is what makes a kill from the wrist signed by the wrist.
///
/// Two simulator hooks survive alongside that, both dev-harness only:
/// `-autoRelayLink` takes a whole `genaryx-pocket://` URL (the relay path,
/// used to drive captures without depending on a live WCSession between two
/// simulators), and `-autoPairURL`/`-autoPairCode` keep the old
/// direct-to-Cloud path for local work with no relay at all.
struct WatchRootView: View {
    @State private var account: Account?
    @State private var pairing = false
    @State private var error: String?
    @State private var inbox = WatchPairingInbox.shared

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            if let account {
                WatchExceptionsView(account: account, onRevoked: sessionRevoked)
            } else {
                // `bootstrap()` hangs off THIS branch, not off the ZStack, so
                // that a revocation restarts it by construction: `account` goes
                // nil, this subview mounts with a fresh identity, its `.task`
                // runs. The obvious alternative - a `@State` token bumped into
                // `.task(id:)` - cancels the running task on every bump, and a
                // second revocation callback arriving mid-redemption would then
                // kill a POST the relay had already answered by burning the
                // one-time code and issuing a session against a key this watch
                // was about to throw away. Mirrors the phone's `ConnectView`.
                unpaired.task { await bootstrap() }
            }
        }
        .foregroundStyle(Palette.fg)
        // A handoff can land while this screen is already up (the phone pairs
        // after the watch app was opened), so react to the inbox as well as
        // reading it once at launch.
        .onChange(of: inbox.pending) { _, intent in
            guard let intent else { return }
            // Already paired, or a redemption is already in flight: drop the
            // handoff rather than starting a second concurrent pair attempt
            // with a second freshly generated key. The loser of that race
            // would lose its 409 after the Cloud had already burned its code.
            guard account == nil, !pairing else {
                inbox.pending = nil
                return
            }
            Task { await redeem(intent) }
        }
    }

    private var unpaired: some View {
        VStack(spacing: 10) {
            BrandMark(size: 46)
            if pairing {
                ProgressView().tint(Palette.mint)
            } else {
                Text(error ?? "Pair TokenFuse on your iPhone. This watch is admitted with it.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(error == nil ? Palette.dim : Palette.ember)
            }
        }
        .padding()
    }

    /// The relay rejected this watch's credential, so stop trusting it.
    ///
    /// Deliberately narrow: fires only on a 401 from the relay, never on a
    /// network failure and never on a 403. There is no re-pair path ON the
    /// watch (no camera, no keyboard); a cleared session can only be replaced
    /// by the phone handing this watch a fresh code, so throwing a good
    /// credential away over a captive portal, a flaky radio or a mere
    /// permission denial would strand the wrist until someone thought to
    /// re-pair it. Everything that is not an explicit "this token matches no
    /// device" keeps its session and merely shows as stale.
    private func sessionRevoked() {
        // Idempotent, and never mid-redemption: concurrent polls can both
        // observe the latch, and a second call while `pairing` is true would
        // pull the session out from under an in-flight `RelayPairingService`
        // call that the relay may already have answered.
        guard account != nil, !pairing else { return }
        SessionStore.clear()
        account = nil
        error = "This watch was disconnected. Pair it again from your iPhone."
    }

    private func bootstrap() async {
        // A stored session still wins over a waiting handoff, on purpose. The
        // tempting fix for the disconnect bug was to check the inbox first, but
        // that lets a stale intent left over from an earlier pairing blow away
        // a HEALTHY session and then fail to redeem an expired code, stranding
        // a watch that was working perfectly.
        //
        // Recovery does not need that reordering: `sessionRevoked` clears the
        // session, this subview remounts, and the handoff below is reached
        // naturally. The old bug was not the ordering, it was that a revoked
        // session was never cleared at all.
        if let (session, key) = SessionStore.load() {
            account = Account(session: session, key: key)
            return
        }
        // A handoff that arrived before this view existed.
        if let pending = inbox.pending {
            await redeem(pending)
            return
        }
        // Dev harness, DEBUG builds only. These accept an attacker-chosen
        // relay URL and pin, so they have no business existing in a shipped
        // binary; the phone's equivalent paste-link field is already
        // `#if DEBUG` (ConnectView), and this now matches it.
        #if DEBUG
        // A whole relay pairing link passed at launch. Accepts either the full
        // two-code QR (take the watch half) or a link whose `code` is already
        // the watch's.
        if let raw = LaunchArgs.value("-autoRelayLink"), let parsed = PairingIntent.parse(raw) {
            await redeem(parsed.watchIntent ?? parsed.asWatchSlot)
            return
        }
        // The older direct-to-Cloud path, no relay involved.
        guard let url = LaunchArgs.value("-autoPairURL"),
              let code = LaunchArgs.value("-autoPairCode") else { return }
        pairing = true
        defer { pairing = false }
        do {
            let (session, key) = try await PairingService.pair(
                planeURL: url, code: code, deviceName: "Apple Watch", platform: "watchos")
            SessionStore.save(session, key: key)
            account = Account(session: session, key: key)
        } catch {
            self.error = error.localizedDescription
        }
        #endif
    }

    /// Redeem a watch-slot intent at the relay, pinned to the QR's own SPKI
    /// hash exactly as the phone does. The intent is cleared either way, so a
    /// spent or rejected code is never retried in a loop.
    private func redeem(_ intent: PairingIntent) async {
        guard !pairing else { return }
        // An intent can now WAIT in the inbox while a doomed session is still
        // live (`WatchLink` parks it rather than dropping it, which is what
        // makes recovery from an admin disconnect possible at all). Waiting
        // means it can time out where it sits, so its window has to be checked
        // here rather than assumed fresh: presenting an expired code just earns
        // an `invalid_or_expired_code` from the relay and leaves the operator
        // staring at a failure with no idea a newer code is needed.
        if let expiry = intent.expiresUnix,
           Date().timeIntervalSince1970 >= Double(expiry) {
            inbox.pending = nil
            error = "That pairing code expired. Show a new QR on the desktop."
            return
        }
        pairing = true
        error = nil
        defer {
            pairing = false
            inbox.pending = nil
        }
        do {
            let (session, key) = try await RelayPairingService.pair(
                intent: intent, deviceName: "Apple Watch")
            SessionStore.save(session, key: key)
            account = Account(session: session, key: key)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
