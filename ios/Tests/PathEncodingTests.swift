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

    /// The invariant the fix rests on: the string that is SIGNED (the path) is
    /// byte-for-byte the raw path the URL carries, which is what the server
    /// reads via `uri.path()`. This mirrors how `Account.signedRequest` builds
    /// the URL (via `percentEncodedPath`, never `URL.appending(path:)`).
    func testSignedPathEqualsTheRawUrlPath() {
        let base = URL(string: "https://5.75.234.176:8443")!
        for id in ["r1", "a/b#c d", "інцидент-42", "weird%2Fid"] {
            let path = "/v1/incidents/\(id.asPathSegment)/ack"
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            comps.percentEncodedPath += path
            let urlRawPath = URLComponents(url: comps.url!, resolvingAgainstBaseURL: false)!
                .percentEncodedPath
            XCTAssertEqual(urlRawPath, path,
                           "the signed path and the URL's raw path must match for id \(id)")
        }
    }
}
