import SwiftUI

/// The signed-in root: a four-tab shell (Fleet / FinOps / Incidents / Governance)
/// that replaces the old header-button navigation off `RunsView`. Owns the
/// selected tab so a deep-linked run (a notification tap via `Router.shared.openRun`,
/// or the `-openRun` launch arg) can bring the Fleet tab to the front — `RunsView`
/// still does the actual push, via its own `Router.shared.openRun` observer.
struct MainTabView: View {
    let account: Account
    var onUnpair: () -> Void

    @State private var selection: Tab = .fleet

    enum Tab: Hashable {
        case fleet, finops, incidents, governance
    }

    var body: some View {
        TabView(selection: $selection) {
            RunsView(account: account, onUnpair: onUnpair)
                .tabItem { Label("Fleet", systemImage: "bolt.horizontal") }
                .tag(Tab.fleet)

            FinOpsView(account: account)
                .tabItem { Label("FinOps", systemImage: "dollarsign.circle") }
                .tag(Tab.finops)

            NavigationStack {
                IncidentsView(account: account)
            }
            .tabItem { Label("Incidents", systemImage: "exclamationmark.triangle") }
            .tag(Tab.incidents)

            NavigationStack {
                GovernanceView(account: account)
            }
            .tabItem { Label("Governance", systemImage: "checkmark.seal") }
            .tag(Tab.governance)
        }
        .tint(Palette.iris)
        .toolbarBackground(Palette.ink, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .onChange(of: Router.shared.openRun) { _, newValue in
            // A run was requested (notification tap while running, or a fresh
            // launch arg) — bring Fleet forward so RunsView's own observer,
            // which does the actual push, is on-screen when it fires.
            if newValue != nil { selection = .fleet }
        }
    }
}

/// Hosts Savings + Agents behind a segmented control, in the same house style
/// `GovernanceView` uses for Evidence/Audit. Each screen keeps its own
/// scroll/refresh/toolbar behavior — the segmented control just swaps which
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
