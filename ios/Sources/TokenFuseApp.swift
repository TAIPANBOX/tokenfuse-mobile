import SwiftData
import SwiftUI

@main
struct TokenFuseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Activate the watch link at launch, not at pairing time: a
        // `transferUserInfo` handoff is queued by the system, and the session
        // has to be up before there is anything to queue onto.
        WatchLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: CachedRun.self)
    }
}
