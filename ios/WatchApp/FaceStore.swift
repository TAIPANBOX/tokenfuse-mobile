import Foundation

/// The tiny slice the watch app hands to its face complication: the fleet's
/// latest burn rate, whether any run is over cap, and whether that pair can be
/// believed at all. Shared through an app group so the complication can render
/// without opening the app.
///
/// `connected` exists because the complication is the surface an operator
/// glances at most and interrogates least. When the relay revoked this watch on
/// 2026-07-20 the app screen froze on a stale snapshot, which was bad; the
/// complication would have been worse either way. Leaving the last real rate
/// there says "the fleet is burning $2.88/min" about a watch that has been cut
/// off, and writing 0.00 instead says the calmest possible lie: nothing is
/// burning, nothing is over cap, all is well. Neither is allowed, so the
/// complication is told plainly that it has no live data.
enum FaceStore {
    static let group = "group.com.taipanbox.tokenfuse"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func save(rate: Double, overCap: Bool) {
        defaults?.set(rate, forKey: "fleetRate")
        defaults?.set(overCap, forKey: "fleetOverCap")
        defaults?.set(true, forKey: "fleetConnected")
    }

    /// This watch is no longer entitled to read the fleet. Keeps the last
    /// figures in place for whatever wants to render them greyed, but marks
    /// them as not live so nothing presents them as current.
    static func saveDisconnected() {
        defaults?.set(false, forKey: "fleetConnected")
    }

    static func load() -> (rate: Double, overCap: Bool, connected: Bool) {
        (defaults?.double(forKey: "fleetRate") ?? 0,
         defaults?.bool(forKey: "fleetOverCap") ?? false,
         // Absent means a build that predates this flag, or a first run with
         // nothing stored: treat as connected so an existing install does not
         // start life claiming to be disconnected.
         defaults?.object(forKey: "fleetConnected") as? Bool ?? true)
    }
}
