import SwiftUI

/// TokenFuse on the wrist: only the runs that are near or over their cap, and
/// a deliberate signed kill for the one that is burning. Shares the design
/// system, API layer and signing with the iPhone app, and is admitted to the
/// relay by the phone's single QR scan (D12 W4).
@main
struct TokenFuseWatchApp: App {
    init() {
        // Up before the first handoff can arrive: WatchConnectivity queues a
        // `transferUserInfo` from the phone, but only onto an activated
        // session.
        WatchLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
