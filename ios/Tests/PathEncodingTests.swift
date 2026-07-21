import Foundation
import XCTest

@testable import TokenFuse

/// The dynamic ids in signed mutation paths (run id, incident id, device id)
/// are percent-encoded as a single path segment before they go into the URL,
/// and the SAME encoded path is what gets signed. This matters because the
/// Cloud verifies the ES256 signature over `uri.path()` -- the raw, encoded
/// request path -- so if the client signed the un-encoded id but sent an
/// encoded URL (the old bug), any id with a reserved character would fail
/// signature verification, not just misroute.
final class PathEncodingTests: XCTestCase {
    func testReservedCharactersAreEncodedInASegment() {
        XCTAssertEqual("a/b".asPathSegment, "a%2Fb", "a slash must not open a new path segment")
        XCTAssertEqual("a b".asPathSegment, "a%20b")
        XCTAssertEqual("a#b".asPathSegment, "a%23b")
        XCTAssertEqual("a?b".asPathSegment, "a%3Fb")
        XCTAssertEqual("a%b".asPathSegment, "a%25b", "a literal percent must survive as data")
    }

    func testOrdinaryIdsAreUnchanged() {
        // The overwhelmingly common case: encoding is a no-op, so existing
        // ids and the pinned cross-language canonical vectors are unaffected.
        XCTAssertEqual("reconciliation-batch-eod-002-s128".asPathSegment,
                       "reconciliation-batch-eod-002-s128")
        XCTAssertEqual("r1".asPathSegment, "r1")
    }

    func testAlreadyEncodedIdIsNotDecoded() {
        // An id that literally contains "%2F" must be preserved verbatim, not
        // silently turned back into a slash.
        XCTAssertEqual("weird%2Fid".asPathSegment, "weird%252Fid")
    }

    /// The invariant the fix rests on, checked against the REAL assembly
    /// (`Account.mutationURL`), not a re-implementation: the string that is
    /// SIGNED (the path) is byte-for-byte the raw path the URL carries, which
    /// is what the Cloud reads via `uri.path()`. Includes a base URL with a
    /// trailing slash: a hand-typed pairing URL must not desync the path (were
    /// this reverted to `appending`/`+=`, the trailing-slash case would fail).
    func testSignedPathEqualsTheRawUrlPath() throws {
        let bases = [
            "https://5.75.234.176:8443",
            "https://5.75.234.176:8443/",
            "http://localhost:8080",
        ]
        for baseString in bases {
            let base = URL(string: baseString)!
            for id in ["r1", "a/b#c d", "інцидент-42", "weird%2Fid"] {
                let path = "/v1/incidents/\(id.asPathSegment)/ack"
                let url = try Account.mutationURL(base: base, encodedPath: path)
                let urlRawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    .percentEncodedPath
                XCTAssertEqual(urlRawPath, path,
                               "signed path must equal the URL's raw path (base \(baseString), id \(id))")
            }
        }
    }
}
