import XCTest

@testable import TokenFuse

/// Verifies the hand-rolled DER SPKI walker (`PinnedTLS.swift`) against a
/// REAL self-signed P-256 certificate (openssl-generated, same curve as
/// `genaryx/crates/relay/src/tls.rs::RelayIdentity::generate`), with the
/// expected pin computed independently via the standard SPKI-pinning
/// one-liner (`openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER
/// | openssl dgst -sha256 -binary | base64`) rather than by the app's own
/// code, so this is a real cross-check, not a tautology.
final class PinnedTLSTests: XCTestCase {
    // CN=genaryx-relay, P-256 (prime256v1), self-signed, 1-day validity.
    private static let certDERBase64 = "MIIBhTCCASugAwIBAgIUFI58VM1St+eEjZnXE2yOZ/JObO0wCgYIKoZIzj0EAwIwGDEWMBQGA1UEAwwNZ2VuYXJ5eC1yZWxheTAeFw0yNjA3MTgyMDU1MDdaFw0yNjA3MTkyMDU1MDdaMBgxFjAUBgNVBAMMDWdlbmFyeXgtcmVsYXkwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQWtIjeONuTr1bh13qbpuNx4RwvtRN8S2G2sI8lKqrEEkr8vhn3C5+Yd0OCokRrkO4qPPafDmUo1K1RzrPSeFowo1MwUTAdBgNVHQ4EFgQUZWoDd402UZaleOikznYekd7DstkwHwYDVR0jBBgwFoAUZWoDd402UZaleOikznYekd7DstkwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEApKARpEWTzYsY8w5VtTyFbEbc9vU5MZPtUYc1NMZPswECIFWoCCp0H3K7XlMKqJWsCSxouNJZwU03gTm1hI0yCSHV"
    private static let expectedPin = "UUCkWgapDC9Wd4w60dQBBzD8yqUHeeYrM4ugAAziCpU="

    func testSpkiPinMatchesIndependentlyComputedGroundTruth() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.certDERBase64))
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let pin = try XCTUnwrap(SpkiPin.sha256Base64(ofCertificate: cert))
        XCTAssertEqual(pin, Self.expectedPin)
    }

    func testSpkiPinIsStableAcrossRepeatedCalls() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.certDERBase64))
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let first = SpkiPin.sha256Base64(ofCertificate: cert)
        let second = SpkiPin.sha256Base64(ofCertificate: cert)
        XCTAssertEqual(first, second)
    }

    func testGarbageDERReturnsNilRatherThanCrashing() throws {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        // Not a valid certificate at all: SecCertificateCreateWithData itself
        // returns nil for non-DER-certificate bytes, before SpkiPin ever runs.
        XCTAssertNil(SecCertificateCreateWithData(nil, junk as CFData))
    }
}

/// The QR payload parser (`RelayPairing.swift`). Pure and deterministic, so
/// worth locking down directly: this is the phone's ONLY gate on what counts
/// as a valid pairing code (docs/PHASE5.md W3: "ACCEPT only
/// genaryx-pocket://pair/v1?..., reject anything else").
final class PairingIntentTests: XCTestCase {
    func testParsesAWellFormedPairingURL() throws {
        let intent = PairingIntent.parse(
            "genaryx-pocket://pair/v1?relay=https://192.168.1.5:8443&pin=UUCkWgapDC9Wd4w60dQBBzD8yqUHeeYrM4ugAAziCpU%3D&code=ABCD1234&org=acme"
        )
        let unwrapped = try XCTUnwrap(intent)
        XCTAssertEqual(unwrapped.relayURL, "https://192.168.1.5:8443")
        XCTAssertEqual(unwrapped.pin, "UUCkWgapDC9Wd4w60dQBBzD8yqUHeeYrM4ugAAziCpU=")
        XCTAssertEqual(unwrapped.code, "ABCD1234")
        XCTAssertEqual(unwrapped.org, "acme")
    }

    func testRejectsTheWrongScheme() {
        XCTAssertNil(PairingIntent.parse("https://pair/v1?relay=https://x&pin=y&code=z&org=acme"))
    }

    func testRejectsTheWrongHost() {
        XCTAssertNil(PairingIntent.parse("genaryx-pocket://notpair/v1?relay=https://x&pin=y&code=z&org=acme"))
    }

    func testRejectsTheWrongPath() {
        XCTAssertNil(PairingIntent.parse("genaryx-pocket://pair/v2?relay=https://x&pin=y&code=z&org=acme"))
    }

    func testRejectsAMissingRequiredField() {
        XCTAssertNil(PairingIntent.parse("genaryx-pocket://pair/v1?relay=https://x&pin=y&code=z"))
    }

    func testRejectsPlainGarbage() {
        XCTAssertNil(PairingIntent.parse("not a url at all"))
        XCTAssertNil(PairingIntent.parse(""))
    }

    func testTrimsSurroundingWhitespaceFromAPastedLink() throws {
        let intent = PairingIntent.parse("  genaryx-pocket://pair/v1?relay=https://x&pin=y&code=z&org=acme\n")
        XCTAssertNotNil(intent)
    }
}
