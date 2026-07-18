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
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let leaf = SpkiPin.leafCertificate(of: serverTrust),
              let presentedHash = SpkiPin.sha256Base64(ofCertificate: leaf),
              presentedHash == pinnedSpkiSha256B64
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
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
