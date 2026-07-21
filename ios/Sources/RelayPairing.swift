import Foundation

/// Which pager surface a code admits. Mirrors the relay's own `DeviceKind`
/// spelling exactly (`registry.rs`), because these strings cross the wire in
/// both directions: out in the QR's parameter names, back in the pair
/// response's `kind` field.
enum PairingKind: String, Equatable {
    case phone
    case watch

    /// The name this device calls itself to the relay. Recorded for display
    /// only: the relay picks the slot from the CODE, never from this string
    /// (`registry.rs`: "the kind is bound to the CODE, never claimed by the
    /// device"), so a lie here buys nothing.
    var platform: String {
        switch self {
        case .phone: "ios"
        case .watch: "watchos"
        }
    }
}

/// The QR payload's parsed pairing intent (itrat-console/13 D12.2 step 3-4):
/// a versioned, custom-scheme URL the desktop's Pocket panel renders and the
/// phone scans. This is the phone's ONLY entry point into the relay pairing
/// flow, so the scheme/host/path triple is checked strictly, not just "looks
/// like a URL" - anything else is rejected outright.
struct PairingIntent: Equatable {
    /// The relay's own HTTPS base URL (the "relay" query param).
    let relayURL: String
    /// SPKI-SHA256 pin (base64) for the relay's self-signed TLS cert.
    let pin: String
    /// The one-time pairing code for THIS device.
    let code: String
    /// The org, informational only - the relay and Cloud remain the actual
    /// authority on which org a pairing redeems into.
    let org: String
    /// The slot `code` admits. The phone's own scan is always `.phone`; the
    /// intent the phone forwards to the watch carries `.watch`.
    let kind: PairingKind
    /// The SECOND one-time code in the same QR, minted for the watch slot.
    /// Optional: a QR from an older desktop has no `code_watch`, which simply
    /// means this pairing admits a phone and no watch. The phone never
    /// redeems this itself, it hands it to the watch over WatchConnectivity.
    let codeWatch: String?
    /// When the relay's armed window closes, if the QR carried it (`exp`).
    /// Forwarded to the watch so a handoff that sat too long in the system's
    /// WatchConnectivity queue is inert on arrival instead of a live code.
    /// Optional: the relay enforces its own window regardless, so an absent
    /// value costs only the early discard.
    let expiresUnix: Int?

    /// Parses and validates a
    /// `genaryx-pocket://pair/v1?relay=...&pin=...&code=...&code_watch=...&org=...`
    /// URL string. Rejects anything else: wrong scheme, wrong host/path, or a
    /// missing/empty required field all fold into one `nil` - deliberately
    /// not distinguishing why to the caller, a malformed or foreign QR is
    /// just "not a pairing code". `code_watch` is the one optional field.
    static func parse(_ raw: String) -> PairingIntent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "genaryx-pocket",
              components.host?.lowercased() == "pair",
              components.path == "/v1"
        else { return nil }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, !value.isEmpty else { continue }
            values[item.name] = value
        }
        guard let relay = values["relay"], let pin = values["pin"],
              let code = values["code"], let org = values["org"],
              URL(string: relay) != nil
        else { return nil }

        return PairingIntent(
            relayURL: relay,
            pin: pin,
            code: code,
            org: org,
            kind: .phone,
            codeWatch: values["code_watch"],
            expiresUnix: values["exp"].flatMap(Int.init)
        )
    }

    /// The intent the phone hands the watch: same relay, same pin, but the
    /// watch's own code and slot. `nil` when the QR carried no watch code, so
    /// a caller cannot accidentally send the watch the phone's already-spent
    /// code.
    var watchIntent: PairingIntent? {
        guard let codeWatch else { return nil }
        return PairingIntent(
            relayURL: relayURL,
            pin: pin,
            code: codeWatch,
            org: org,
            kind: .watch,
            codeWatch: nil,
            expiresUnix: expiresUnix
        )
    }

    /// The same code, reinterpreted as a watch-slot claim. Only for the
    /// simulator harness, where a link may be handed to the watch whose `code`
    /// is ALREADY the watch's half. It changes nothing at the relay, which
    /// picks the slot from the code regardless; if the guess is wrong the
    /// relay's `kind` in the pair response catches it and pairing fails loudly
    /// rather than landing in the wrong slot.
    var asWatchSlot: PairingIntent {
        PairingIntent(
            relayURL: relayURL, pin: pin, code: code, org: org, kind: .watch,
            codeWatch: nil, expiresUnix: expiresUnix)
    }
}

/// Redeems a relay pairing intent from a scanned or pasted QR URL
/// (itrat-console/13 D12.2 step 5-9): generates the device key, POSTs
/// `{relay}/relay/v1/pair` over a TLS session pinned to the QR's OWN SPKI
/// hash (a mismatch aborts before any data leaves the device), and returns
/// the resulting session + key ready for `SessionStore.save`. Distinct from
/// `PairingService.pair` (Session.swift), which redeems a code directly
/// against a Cloud plane for the unpinned, direct-to-Cloud dev-harness path
/// (`-autoPairURL`/`-autoPairCode`) - different wire shape
/// (`pubkey_x963_b64`, not `pubkey_b64`), different trust model, and the
/// relay's response is the authority on `plane_url`, not the caller's input.
enum RelayPairingService {
    struct PairError: LocalizedError {
        let errorDescription: String?
    }

    static func pair(intent: PairingIntent, deviceName: String) async throws -> (DeviceSession, DeviceKey) {
        guard let relayBase = URL(string: intent.relayURL), relayBase.scheme == "https" else {
            throw PairError(errorDescription: "The relay address in this code isn't a valid HTTPS URL.")
        }

        // This device's OWN key, generated here and never shared. The watch
        // redeems its own code with its own key, which is what makes a kill
        // from the wrist signed by the wrist rather than by a key borrowed
        // from the phone.
        let key = try DeviceKeyFactory.generate()
        let payload: [String: String] = [
            "code": intent.code,
            "pubkey_x963_b64": key.publicKeyX963.base64EncodedString(),
            "platform": intent.kind.platform,
            "name": deviceName,
            // Declare the slot we believe this code is for, so the relay can
            // refuse a crossed code BEFORE it redeems it at the Cloud. The
            // check below still runs as a second line, but by then the code is
            // spent and the slot is filled, so catching it here is what keeps
            // a mis-built QR recoverable.
            "expect_kind": intent.kind.rawValue,
        ]
        var request = URLRequest(url: relayBase.appending(path: "relay/v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // Pinned to the QR's OWN SPKI hash, not yet a persisted session - a
        // mismatch here means the code was scanned from an untrusted relay,
        // and the phone must abort before it ever spends the one-time code
        // (docs/PHASE5.md; itrat-console/13 D12.3: keep the pin check
        // strict, mismatch = hard abort).
        let pinnedSession = URLSession(
            configuration: .ephemeral,
            delegate: PinnedURLSessionDelegate(pinnedSpkiSha256B64: intent.pin),
            delegateQueue: nil
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await pinnedSession.data(for: request)
        } catch {
            throw PairError(errorDescription: "Couldn't reach the relay securely (\(error.localizedDescription)). If this relay's certificate doesn't match the pairing code's pin, pairing is refused by design.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw PairError(errorDescription: "No response from the relay.")
        }
        guard http.statusCode == 200 else {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = body?["error"] as? String
            throw PairError(errorDescription: code.map { "Pairing failed: \($0)." } ?? "Pairing failed, the code may be wrong or expired (HTTP \(http.statusCode)).")
        }

        struct RelayPairResponse: Decodable {
            let planeUrl: String
            let deviceId: String
            let deviceToken: String
            let org: String
            let role: String
            /// Which slot the relay actually admitted this device to. Optional
            /// so an older relay that does not send it still pairs.
            let kind: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(RelayPairResponse.self, from: data)

        // Refuse a crossed pair. If the desktop ever put the codes in the
        // wrong QR parameters, the watch would be admitted to the phone slot
        // with a perfectly valid code and would silently become the phone.
        // The relay tells us which slot it used, so check it rather than
        // assume, and fail loudly while the mistake is still one QR away.
        if let admitted = result.kind, admitted != intent.kind.rawValue {
            throw PairError(errorDescription: "This code paired as \"\(admitted)\", not \"\(intent.kind.rawValue)\". The pairing QR looks crossed, generate a new one on the desktop.")
        }

        let session = DeviceSession(
            planeURL: result.planeUrl,
            deviceId: result.deviceId,
            deviceToken: result.deviceToken,
            org: result.org,
            role: result.role,
            pin: intent.pin
        )
        return (session, key)
    }
}
