import SwiftUI

/// The signed-in root, and there is only one of it.
///
/// This used to branch on `session.pin`: a direct-to-Cloud session got a
/// four-tab shell over `/v1/runs`, a relay-paired one got the exception queue
/// alone. The free mode is gone (itrat-console/14 D14.6): the app pairs to a
/// Genaryx relay or it does nothing, TokenFuse's own dashboard is the free
/// tier, and with the branch went the only code path that ever connected
/// without a pinned certificate.
///
/// Three tabs, in the order they matter at 2am. The queue is first because it
/// is what interrupts you; Money and Agents are pulls, opened deliberately,
/// and they are served by the relay's own bounded roll-up
/// (`GET /relay/v1/money`), never by browsing the fleet.
struct MainTabView: View {
    let account: Account
    var onUnpair: () -> Void

    @State private var selection: Tab = .exceptions

    /// Screenshot / UI-check hook, DEBUG builds only, alongside the existing
    /// `-autoRelayLink` and `-openRun`: the Simulator has no way to tap a tab
    /// from the command line, so a capture session cannot reach Money or Agents
    /// without one. Names a tab, nothing more, and cannot reach anything a user
    /// could not.
    private static var launchTab: Tab? {
        #if DEBUG
        switch LaunchArgs.value("-openTab") {
        case "money": return .money
        case "agents": return .agents
        case "exceptions": return .exceptions
        default: return nil
        }
        #else
        return nil
        #endif
    }

    enum Tab: Hashable {
        case exceptions, money, agents
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                ExceptionQueueView(account: account, onUnpair: onUnpair)
            }
            .tabItem { Label("Exceptions", systemImage: "exclamationmark.triangle") }
            .tag(Tab.exceptions)

            MoneyView(account: account)
                .tabItem { Label("Money", systemImage: "dollarsign.circle") }
                .tag(Tab.money)

            AgentsRelayView(account: account, onUnpair: onUnpair)
                .tabItem { Label("Agents", systemImage: "person.2") }
                .tag(Tab.agents)
        }
        .tint(Palette.iris)
        .toolbarBackground(Palette.ink, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .task {
            if let tab = Self.launchTab { selection = tab }
        }
        .onChange(of: Router.shared.openRun) { _, newValue in
            // A run was requested (a notification tap, or a launch arg): the
            // queue is the only screen that can open one, so bring it forward
            // and let its own observer do the push.
            if newValue != nil { selection = .exceptions }
        }
    }
}

/// Hosts Savings + Agents behind a segmented control, in the same house style
/// `GovernanceView` uses for Evidence/Audit. Each screen keeps its own
/// scroll/refresh/toolbar behavior: the segmented control just swaps which
/// one is mounted.
struct FinOpsView: View {
    let account: Account

    @State private var section: Section = .savings

    enum Section: String, CaseIterable, Hashable {
        case savings = "Savings"
        case agents = "Agents"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentedControl
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                content
            }
            .background(Palette.ink.ignoresSafeArea())
        }
        .tint(Palette.iris)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .savings: SavingsView(account: account)
        case .agents: AgentsView(account: account)
        }
    }

    private var segmentedControl: some View {
        HStack(spacing: 8) {
            ForEach(Section.allCases, id: \.self) { candidate in
                Button {
                    section = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(section == candidate ? Palette.ink : Palette.dim)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(section == candidate ? Palette.iris : Palette.panel, in: Capsule())
                        .overlay(Capsule().stroke(section == candidate ? Color.clear : Palette.line))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == candidate ? [.isSelected] : [])
            }
        }
    }
}

/// A minimal settings sheet, reached from the Fleet tab's gear button: paired
/// org / plane / role, and the destructive "Unpair this device" action that
/// used to live in the Fleet header.
struct DeviceSettingsSheet: View {
    let account: Account
    var onUnpair: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.instrument(26))

                VStack(alignment: .leading, spacing: 12) {
                    settingsRow(label: "Org", value: account.session.org)
                    settingsRow(label: "Plane", value: account.reads.baseURL.host() ?? account.session.planeURL)
                    settingsRow(label: "Role", value: account.session.role)
                    if let pin = account.session.pin {
                        settingsRow(label: "TLS pin", value: "\(pin.prefix(12))…")
                    }
                }
                .padding(14)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))

                Spacer()

                Button {
                    confirmingUnpair = true
                } label: {
                    HStack {
                        Image(systemName: "iphone.slash")
                        Text("Unpair this device")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .foregroundStyle(Palette.ember)
                    .background(Palette.ember.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ember.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unpair this device")
                .accessibilityHint("Removes this device's pairing and returns to the pairing screen")
            }
            .padding(22)
        }
        .foregroundStyle(Palette.fg)
        .presentationDetents([.medium])
        .presentationBackground(Palette.ink)
        .confirmationDialog(
            "Unpair this device?",
            isPresented: $confirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                dismiss()
                onUnpair()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone will need a new pairing code to reconnect.")
        }
    }

    private func settingsRow(label: String, value: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(Palette.faint)
            Spacer()
            Text(value).font(.mono).foregroundStyle(Palette.dim)
        }
        .accessibilityElement(children: .combine)
    }
}
