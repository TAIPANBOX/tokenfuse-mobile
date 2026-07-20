import XCTest

@testable import TokenFuse

/// Locks in the rule the watch got wrong on 2026-07-20.
///
/// The relay revoked this watch's credential (an operator pressed Disconnect on
/// the desktop) and the wrist carried on rendering its last snapshot as though
/// current: a real burn figure, real over-cap rows, no hint that any of it was
/// dead. For a pager whose entire job is "something is burning RIGHT NOW", a
/// frozen snapshot shown as live is the worst failure this product has, and it
/// is worse than showing nothing.
///
/// The distinction these tests exist to defend is narrow and deliberate:
/// - **401 and nothing else** means the credential is gone. It never recovers
///   on its own, so the snapshot is dropped and the view is told to re-pair.
/// - **403 is NOT that.** The relay draws the line itself: a 403 means the
///   device IS paired and merely may not do this, while 401 is reserved for a
///   token matching no device. Treating 403 as revocation would let a future
///   permission gate on a read route destroy this watch's Secure Enclave key
///   and its kill authority in answer to "you may not".
/// - **Anything else** (a dropped radio, a 5xx, a captive portal) is transient.
///   The snapshot survives, because a watch that blanks every time it walks
///   through a lift is useless, and because there is no re-pair path ON the
///   watch: throwing a good credential away over a blip would strand it until
///   someone thought to re-pair from the phone.
@MainActor
final class WatchExceptionsStoreTests: XCTestCase {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://relay.test")!,
            token: "device-token",
            session: URLSession(configuration: config)
        )
    }

    /// One over-cap run plus aggregates, snake_case exactly as the relay's
    /// `ExceptionSnapshot` puts it on the wire.
    private static let snapshotJSON = """
    {"aggregates":{"spend_microusd":41080000,"headroom_microusd":2070000,
      "burn_rate_microusd_per_min":880000,"updated_at_unix":1784411000},
     "queue":[{"key":"run:reconciliation-batch-eod-002-s128",
       "run_id":"reconciliation-batch-eod-002-s128","incident_id":null,
       "kind":"kill","class":"over_cap","severity":"hard",
       "headline":"Run reconciliation-batch-eod-002-s128 at 116% of budget",
       "spent_microusd":530000,"budget_micros":460000,"fraction":1.16,
       "first_seen_unix":1784410000,"last_seen_unix":1784411000,
       "acknowledged":false,"killed":false}]}
    """

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// The house pattern from `ExceptionQueueStoreTests`: the mock returns a
    /// real `HTTPURLResponse`, so the status code travels the same path the
    /// live client takes.
    private func respond(_ status: Int, _ body: String = "") {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    private func loadOnce(_ store: WatchExceptionsStore) async {
        await store.load(using: makeClient())
    }

    /// A good load populates, and is not stale.
    func testSuccessfulLoadPopulatesAndIsNotStale() async {
        respond(200, Self.snapshotJSON)
        let store = WatchExceptionsStore()
        await loadOnce(store)

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.queue.count, 1)
        XCTAssertNotNil(store.aggregates)
        XCTAssertNil(store.stalenessSeconds(), "a fresh load is not stale")
    }

    /// THE REGRESSION. A 401 must clear everything, not keep the last snapshot.
    /// Before the fix this assertion failed on every line: the queue, the
    /// aggregates and the digest all survived a revocation and kept rendering.
    func testUnauthorizedDropsTheSnapshotInsteadOfShowingItAsLive() async {
        respond(200, Self.snapshotJSON)
        let store = WatchExceptionsStore()
        await loadOnce(store)
        XCTAssertFalse(store.queue.isEmpty, "precondition: something to lose")

        respond(401)
        await loadOnce(store)

        XCTAssertTrue(store.deauthorized, "a 401 must latch the revocation")
        XCTAssertTrue(store.queue.isEmpty, "a revoked watch must show no runs")
        XCTAssertNil(store.aggregates, "and no burn figure")
        XCTAssertTrue(store.digest.isEmpty)
        XCTAssertEqual(store.queueTruncated, 0)
        XCTAssertNil(store.stalenessSeconds(),
                     "nothing is on screen to be stale about")
    }

    /// THE SECURITY INVARIANT. A 403 says "you are paired, you may not do
    /// this". Destroying the session over it would trade a permission denial
    /// for a wiped signing key and a wrist that can no longer kill anything.
    func testForbiddenIsNotTreatedAsRevocation() async {
        respond(200, Self.snapshotJSON)
        let store = WatchExceptionsStore()
        await loadOnce(store)

        respond(403)
        await loadOnce(store)

        XCTAssertFalse(store.deauthorized, "403 must never revoke the session")
        XCTAssertEqual(store.queue.count, 1, "and must not drop the snapshot")
        XCTAssertNotNil(store.aggregates)
    }

    /// A success that was already on the wire when the revocation landed must
    /// not put the dead fleet back on screen. `load()` has no reentrancy guard
    /// and is called from the poll loop, `.refreshable`, `scenePhase` and the
    /// kill ceremony, so this ordering is reachable in normal use.
    func testLateSuccessCannotUndoTheRevocation() async {
        respond(401)
        let store = WatchExceptionsStore()
        await loadOnce(store)
        XCTAssertTrue(store.deauthorized)

        respond(200, Self.snapshotJSON)
        await loadOnce(store)

        XCTAssertTrue(store.deauthorized, "the latch is one-way")
        XCTAssertTrue(store.queue.isEmpty, "and the fleet stays off the screen")
        XCTAssertNil(store.aggregates)
    }

    /// The other half of the rule: a transient failure must NOT throw the
    /// snapshot away. If this ever starts passing by clearing the queue, a
    /// watch would blank itself every time its radio hiccups, with no way back
    /// except re-pairing from the phone.
    func testTransientFailureKeepsTheLastKnownGoodSnapshot() async {
        respond(200, Self.snapshotJSON)
        let store = WatchExceptionsStore()
        await loadOnce(store)

        respond(503)
        await loadOnce(store)

        XCTAssertEqual(store.queue.count, 1, "a 5xx is a blip, not a revocation")
        XCTAssertNotNil(store.aggregates)
        XCTAssertFalse(store.deauthorized,
                       "a 5xx must never be treated as a revoked credential")
    }

    /// The staleness marker has to appear on a clock, not on a state change:
    /// while the relay is unreachable each poll sits in URLSession's timeout,
    /// so a view waiting for the store to mutate would show the frozen figure
    /// unmarked for most of the window that matters.
    func testStalenessIsReportedAgainstAClock() async {
        respond(200, Self.snapshotJSON)
        let store = WatchExceptionsStore()
        await loadOnce(store)

        let loadedAt = try! XCTUnwrap(store.lastLoadedAt)
        XCTAssertNil(store.stalenessSeconds(now: loadedAt.addingTimeInterval(19)),
                     "under four missed polls is ordinary jitter")
        let late = store.stalenessSeconds(now: loadedAt.addingTimeInterval(21))
        XCTAssertNotNil(late, "past the threshold it must be visible")
        XCTAssertEqual(late ?? 0, 21, accuracy: 0.5)
    }

    /// With nothing loaded yet, a transient failure is what the user sees.
    func testFirstLoadFailureSurfacesAsFailed() async {
        respond(503)
        let store = WatchExceptionsStore()
        await loadOnce(store)

        guard case .failed = store.phase else {
            return XCTFail("expected .failed, got \(store.phase)")
        }
        XCTAssertNil(store.aggregates)
    }
}
