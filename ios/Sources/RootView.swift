import SwiftUI

/// Shows the fleet when a paired session exists, otherwise the pairing screen,
/// behind the brand for the first beat either way. The session (device token +
/// signing key) lives in the Keychain.
struct RootView: View {
    @State private var account: Account?
    @State private var restored = false
    /// The splash covers the restore, so a paired launch never opens on an
    /// empty queue that has not been filled yet. An empty queue is supposed to
    /// mean calm, and it must not be able to mean "still loading".
    @State private var splashDone = false

    var body: some View {
        Group {
            if !splashDone {
                SplashView().transition(.opacity)
            } else if let account {
                MainTabView(account: account, onUnpair: unpair)
            } else {
                ConnectView { account = $0 }
            }
        }
        .task {
            guard !restored else { return }
            restored = true
            if let (session, key) = SessionStore.load() {
                account = Account(session: session, key: key)
            }
            try? await Task.sleep(for: SplashView.hold)
            withAnimation(.easeInOut(duration: 0.3)) { splashDone = true }
        }
        .onChange(of: Router.shared.apnsToken) { _, token in
            if let account, let token {
                Task { await account.registerAPNs(token: token) }
            }
        }
    }

    private func unpair() {
        SessionStore.clear()
        account = nil
    }
}
