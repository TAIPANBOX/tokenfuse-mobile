import Foundation

/// Loads `GET /relay/v1/exceptions` for the watch. Keeps the last-known-good
/// snapshot on a transient poll failure, exactly like the phone's
/// `ExceptionQueueStore` - only surfaces an error when there is nothing yet
/// to show.
@MainActor
@Observable
final class WatchExceptionsStore {
    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var aggregates: ExceptionAggregates?
    private(set) var queue: [ExceptionItem] = []
    private(set) var digest: [ExceptionDigestRow] = []
    private(set) var queueTruncated: Int = 0

    /// Set when the relay rejects this watch's device token (HTTP 401): it was
    /// disconnected server-side, by the desktop's Disconnect button or by
    /// another watch claiming the single watch slot. A ONE-WAY LATCH, never
    /// cleared by a later success, and deliberately a latch rather than a
    /// `Phase` case: `load()` has no reentrancy guard and is called from the
    /// poll loop, `.refreshable`, `scenePhase` and the kill ceremony, so a
    /// success that was already in flight when the revocation landed would
    /// otherwise overwrite the state and put the dead fleet back on screen.
    ///
    /// Mirrors `ExceptionQueueStore.deauthorized` on the phone, which has
    /// shipped this exact rule since PHASE5 W4. The watch simply never got it,
    /// which is why on 2026-07-20 a disconnected wrist carried on showing
    /// $4547.66 and a live-looking exception list.
    private(set) var deauthorized = false

    /// When the last SUCCESSFUL load landed, and when the last attempt of any
    /// kind did. Both are stamped by the load itself rather than read from the
    /// clock while rendering, so staleness is a value the view observes and
    /// re-renders on rather than something that silently goes out of date.
    private(set) var lastLoadedAt: Date?
    private(set) var lastAttemptAt: Date?

    /// How far behind the numbers on screen are, once that gap is worth saying
    /// out loud. `nil` while they are current.
    ///
    /// A pager exists to say "this is burning RIGHT NOW", so a frozen snapshot
    /// rendered as current is this product's worst failure mode. Four missed
    /// polls is the threshold: one or two are ordinary jitter on a watch that
    /// sleeps its radio, four means something is actually wrong.
    ///
    /// Takes `now` so the view can drive it from a periodic clock. While the
    /// relay is unreachable each poll sits in `URLSession`'s own timeout, so
    /// waiting for the next `lastAttemptAt` mutation to re-render would leave
    /// the marker up to a minute late - exactly the window in which the stale
    /// figure does its damage.
    func stalenessSeconds(now: Date = Date()) -> TimeInterval? {
        guard let lastLoadedAt else { return nil }
        let age = now.timeIntervalSince(lastLoadedAt)
        return age >= Self.staleAfter ? age : nil
    }

    private static let staleAfter: TimeInterval = 20

    func load(using client: APIClient) async {
        if aggregates == nil, phase != .loaded { phase = .loading }
        do {
            let snapshot = try await client.exceptions()
            // A response that was already on the wire when the credential was
            // revoked must not resurrect the fleet on screen.
            guard !deauthorized else { return }
            lastLoadedAt = Date()
            lastAttemptAt = lastLoadedAt
            aggregates = snapshot.aggregates
            digest = snapshot.digest
            queueTruncated = snapshot.queueTruncated
            // Server order, rendered as given. This used to re-sort by its own
            // rule while the phone showed the server's, so one fleet read two
            // different ways on the two surfaces of the same product. The order
            // now lives once, in the relay (`exceptions.rs::queue_order`):
            // over the cap worst-first, then still-running detections, then
            // near cap. Killed runs and anything below the alert threshold are
            // filtered out server-side and never arrive here at all.
            queue = snapshot.queue
            phase = .loaded
        } catch APIClient.ClientError.http(401) {
            // Revoked, not unreachable. Drop the snapshot on the floor: it
            // describes a fleet this watch is no longer entitled to read, and
            // every second it stays up is a second the wrist is lying about a
            // number someone might act on.
            //
            // 401 ONLY, never 403. The relay draws that line itself
            // (`crates/relay/src/proxy.rs`): a 403 means the device IS paired
            // and merely may not do this, while 401 is reserved for a token
            // that matches no device. Treating 403 as revocation would make a
            // future permission gate on a read route destroy this watch's
            // Secure Enclave key and its kill authority in response to "you
            // may not", recoverable only by re-pairing from the phone.
            deauthorized = true
            aggregates = nil
            queue = []
            digest = []
            queueTruncated = 0
            lastLoadedAt = nil
            lastAttemptAt = Date()
        } catch {
            lastAttemptAt = Date()
            if aggregates == nil { phase = .failed(error.localizedDescription) }
            // else: keep showing the last-known-good snapshot, now visibly
            // marked stale by `stalenessSeconds` once it falls far enough
            // behind. A watch that blanked itself every time its radio hiccups
            // would be useless, and there is no re-pair path ON the watch.
        }
    }
}
