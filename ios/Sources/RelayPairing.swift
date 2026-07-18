import Foundation

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
    /// The one-time pairing code.
    let code: String
    /// The org, informational only - the relay and Cloud remain the actual
    /// authority on which org a pairing redeems into.
    let org: String

    /// Parses and validates a
    /// `genaryx-pocket://pair/v1?relay=...&pin=...&code=...&org=...` URL
    /// string. Rejects anything else: wrong scheme, wrong host/path, or a
    /// missing/empty required field all fold into one `nil` - deliberately
    /// not distinguishing why to the caller, a malformed or foreign QR is
    /// just "not a pairing code".
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

        return PairingIntent(relayURL: relay, pin: pin, code: code, org: org)
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

    static func pair(intent: PairingIntent, deviceName: String, platform: String = "ios") async throws -> (DeviceSession, DeviceKey) {
        guard let relayBase = URL(string: intent.relayURL), relayBase.scheme == "https" else {
            throw PairError(errorDescription: "The relay address in this code isn't a valid HTTPS URL.")
        }

        let key = try DeviceKeyFactory.generate()
        let payload: [String: String] = [
            "code": intent.code,
            "pubkey_x963_b64": key.publicKeyX963.base64EncodedString(),
            "platform": platform,
            "name": deviceName,
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
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(RelayPairResponse.self, from: data)

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
