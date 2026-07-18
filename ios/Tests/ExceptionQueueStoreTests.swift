import XCTest

@testable import TokenFuse

/// Covers the relay-revocation behavior of `ExceptionQueueStore` (docs/PHASE5
/// W4): a 401 from the relay means this device was disconnected server-side
/// (the desktop's Disconnect button, or another phone claiming the single
/// device slot), and must surface as `deauthorized` so the view falls back to
/// the Connect screen - NOT be swallowed like a transient blip, which would
/// leave a frozen last-known-good queue on screen behind a green
/// "connected" dot.
@MainActor
final class ExceptionQueueStoreTests: XCTestCase {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://relay.test")!,
            token: "device-token",
            session: URLSession(configuration: config)
        )
    }

    /// One over-cap run + aggregates, snake_case on the wire exactly as the
    /// relay's `ExceptionSnapshot` serializes it.
    private static let snapshotJSON = """
    {"aggregates":{"spend_microusd":41080000,"headroom_microusd":2070000,
      "burn_rate_microusd_per_min":0,"updated_at_unix":1784411000},
     "queue":[{"key":"run:support-tier2-bot-000","run_id":"support-tier2-bot-000",
       "incident_id":null,"kind":"kill","class":"over_cap","severity":"hard",
       "headline":"Run support-tier2-bot-000 at 117% of budget","spent_microusd":961543,
       "budget_micros":820000,"fraction":1.17,"first_seen_unix":1784410000,
       "last_seen_unix":1784411000,"acknowledged":false,"killed":false}]}
    """

    func testUnauthorizedFlipsDeauthorized() async {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/relay/v1/exceptions")
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let store = ExceptionQueueStore()
        await store.load(using: makeClient())
        XCTAssertTrue(store.deauthorized, "a 401 must deauthorize -> Connect screen")
        XCTAssertNil(store.aggregates, "nothing was ever loaded")
    }

    func testTransientErrorKeepsLastKnownGoodAndDoesNotDeauthorize() async {
        // First: a good load populates the store.
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(Self.snapshotJSON.utf8))
        }
        let store = ExceptionQueueStore()
        let client = makeClient()
        await store.load(using: client)
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.queue.count, 1)
        XCTAssertEqual(store.queue.first?.runId, "support-tier2-bot-000")

        // Then: a transient 5xx must NOT deauthorize and must keep the
        // last-known-good snapshot on screen (unchanged "estimate-then-settle").
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data("upstream unavailable".utf8))
        }
        await store.load(using: client)
        XCTAssertFalse(store.deauthorized, "a 5xx is a transient blip, not a revocation")
        XCTAssertEqual(store.queue.count, 1, "last-known-good queue retained")
        XCTAssertEqual(store.phase, .loaded, "stays loaded; no error card over good data")
    }
}
