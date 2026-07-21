import CryptoKit
import Foundation
import Security

/// Enforces the QR-delivered SPKI-SHA256 pin on every TLS handshake to the
/// relay (docs/PHASE5.md W3; itrat-console/13 D12.2 step 6, D12.3 R2: "no
/// public CA, no domain requirement, works on IP-only enterprise networks").
/// The relay's certificate is self-signed, so ordinary system trust
/// evaluation is deliberately bypassed entirely - trust is anchored ONLY in
/// the pinned hash. Any failure to compute the presented certificate's SPKI
/// hash, or a mismatch, is a hard abort: the challenge is cancelled, never
/// handed to `.performDefaultHandling`.
final class PinnedURLSessionDelegate: NSObject, URLSessionDelegate {
    private let pinnedSpkiSha256B64: String

    init(pinnedSpkiSha256B64: String) {
        self.pinnedSpkiSha256B64 = pinnedSpkiSha256B64
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Each refusal says WHICH check failed. A pairing that dies inside TLS
        // is otherwise indistinguishable from the relay being unreachable, and
        // the operator has no way to tell "wrong relay" from "no network".
        // Nothing secret is logged: the pin travels in the QR in plain sight,
        // and is the public half of the relay's key by construction.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        else {
            NSLog("PinnedTLS: refusing, not a server-trust challenge (\(challenge.protectionSpace.authenticationMethod))")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            NSLog("PinnedTLS: refusing, the challenge carried no server trust")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let leaf = SpkiPin.leafCertificate(of: serverTrust) else {
            NSLog("PinnedTLS: refusing, could not read a leaf certificate from the chain")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let presentedHash = SpkiPin.sha256Base64(ofCertificate: leaf) else {
            NSLog("PinnedTLS: refusing, could not compute the presented SPKI hash")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard presentedHash == pinnedSpkiSha256B64 else {
            NSLog("PinnedTLS: refusing, pin mismatch. presented=\(presentedHash) expected=\(pinnedSpkiSha256B64)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // The pin matched, but that is not yet enough to connect.
        //
        // Returning `.useCredential` with a trust object that FAILS the
        // system's own evaluation does not work: CFNetwork re-evaluates and
        // refuses it anyway. Observed against the live relay, two milliseconds
        // after this delegate approved:
        //
        //   PinnedTLS: pin matched, accepting ...
        //   Trust evaluate failure: [leaf AnchorTrusted SSLHostname]
        //   HTTP load failed (error -1200 [3:-9802])
        //
        // All three complaints are expected and none of them is the trust
        // decision we actually make. The relay's certificate is self-signed
        // (so it has no CA anchor) and is reached by IP while its SAN is
        // `DNS:genaryx-relay` (so the hostname will never match). Identity
        // here is the PIN, delivered by a QR the operator physically scanned
        // off their own desktop.
        //
        // So make the trust object express that, and only then hand it back:
        // the presented leaf becomes its own and ONLY anchor, and the policy
        // drops the hostname check. This is STRICTER than system trust, not
        // looser: after these two calls exactly one certificate in the world
        // is acceptable, the one whose public key we just matched byte for
        // byte. Order matters, none of this runs unless the pin matched above.
        SecTrustSetAnchorCertificates(serverTrust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)
        SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, nil))

        var evaluationError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &evaluationError) else {
            // The pinned certificate cannot even validate against itself:
            // expired, malformed, or a key the platform refuses. Fail closed.
            NSLog("PinnedTLS: refusing, the pinned certificate failed its own evaluation: \(String(describing: evaluationError))")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        NSLog("PinnedTLS: pin matched, accepting the relay's self-signed certificate")
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

/// SPKI-SHA256 pin computation, matching `genaryx/crates/relay/src/tls.rs::spki_pin`
/// byte for byte: SHA-256 of the DER-encoded SubjectPublicKeyInfo structure
/// (RFC 5280), base64-encoded. iOS has no public API that hands back a
/// certificate's SPKI DER directly, so this walks the certificate's own DER
/// bytes (Certificate -> TBSCertificate -> ordered fields) to find it,
/// rather than assuming a key algorithm: it works for whatever key type the
/// presented certificate actually carries, and hashes exactly the same bytes
/// `rcgen::KeyPair::public_key_der()` produces server-side (both are the DER
/// encoding of the same public key info).
enum SpkiPin {
    static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return nil }
        return chain.first
    }

    static func sha256Base64(ofCertificate certificate: SecCertificate) -> String? {
        let der = SecCertificateCopyData(certificate) as Data
        guard let spki = subjectPublicKeyInfo(fromCertificateDER: der) else { return nil }
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    // ---- minimal DER TLV walker --------------------------------------------

    private struct Tlv {
        let tag: UInt8
        let start: Int
        let contentStart: Int
        let contentEnd: Int
        let end: Int
    }

    /// Reads one tag-length-value at `offset`. Definite-length short and long
    /// form only (X.509 never uses indefinite length); returns `nil` rather
    /// than trapping on any malformed or truncated input.
    private static func readTLV(_ bytes: [UInt8], at offset: Int) -> Tlv? {
        guard offset >= 0, offset < bytes.count else { return nil }
        let tag = bytes[offset]
        var pos = offset + 1
        guard pos < bytes.count else { return nil }
        let firstLenByte = bytes[pos]
        pos += 1
        let length: Int
        if firstLenByte & 0x80 == 0 {
            length = Int(firstLenByte)
        } else {
            let numBytes = Int(firstLenByte & 0x7F)
            guard numBytes > 0, numBytes <= 4, pos + numBytes <= bytes.count else { return nil }
            var len = 0
            for i in 0..<numBytes { len = (len << 8) | Int(bytes[pos + i]) }
            pos += numBytes
            length = len
        }
        let contentStart = pos
        let contentEnd = pos + length
        guard contentEnd >= contentStart, contentEnd <= bytes.count else { return nil }
        return Tlv(tag: tag, start: offset, contentStart: contentStart, contentEnd: contentEnd, end: contentEnd)
    }

    /// The full DER TLV (its own SEQUENCE tag + length + content) of
    /// `TBSCertificate.subjectPublicKeyInfo`: the 7th field of
    /// TBSCertificate when the optional `version [0]` tag is present (always,
    /// for an rcgen-issued v3 cert), the 6th when it is omitted.
    private static func subjectPublicKeyInfo(fromCertificateDER der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let certificate = readTLV(bytes, at: 0), certificate.tag == 0x30,
              let tbs = readTLV(bytes, at: certificate.contentStart), tbs.tag == 0x30
        else { return nil }

        var pos = tbs.contentStart
        var fieldIndex = 0
        while pos < tbs.contentEnd {
            guard let field = readTLV(bytes, at: pos) else { return nil }
            if fieldIndex == 0 && field.tag == 0xA0 {
                pos = field.end // explicit [0] version tag: optional, does not count
                continue
            }
            fieldIndex += 1
            // Field order after version: serialNumber(1) signature(2)
            // issuer(3) validity(4) subject(5) subjectPublicKeyInfo(6).
            if fieldIndex == 6 {
                return Data(bytes[field.start..<field.end])
            }
            pos = field.end
        }
        return nil
    }
}
