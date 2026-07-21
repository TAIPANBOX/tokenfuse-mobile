import SwiftUI

/// The Agents tab, fed by the relay's roll-up rather than by browsing runs.
///
/// Named `AgentsRelayView` to stand apart from the older `AgentsView`, which
/// reads Cloud's `/v1/agents` directly and belongs to a shell this app no
/// longer has. The relay-served list is bounded by construction, so this screen
/// can never turn into the fleet browser the whole design exists to avoid: when
/// the cap bites, the count and the hidden spend are shown rather than swallowed.
struct AgentsRelayView: View {
    let account: Account

    @State private var store = MoneyStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if case .failed(let message) = store.phase, !store.hasSnapshot {
                        FailureCard(message: message)
                    }
                    if store.agents.isEmpty, store.phase == .loading {
                        ProgressView().tint(Palette.iris)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(store.agents) { agent in
                        row(agent)
                    }
                    if store.agentsTruncated > 0 {
                        truncationNote
                    }
                }
                .padding(18)
            }
            .background(Palette.ink.ignoresSafeArea())
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task { await load() }
        }
        .tint(Palette.iris)
    }

    private func row(_ agent: AgentRollup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.shortName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(agent.isUnattributed ? Palette.dim : Palette.fg)
                Text("\(agent.calls) calls \u{00B7} \(agent.runs) runs")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.faint)
            }
            Spacer()
            Text(String(format: "$%.2f", agent.spent))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
        }
        .padding(14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
    }

    /// A cut list says so. `others_spent_microusd` exists precisely so this
    /// sentence can carry a number instead of an apology.
    private var truncationNote: some View {
        Text("and \(store.agentsTruncated) more, \(String(format: "$%.2f", store.othersSpent)) between them")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Palette.faint)
            .padding(.top, 4)
    }

    private func load() async {
        await store.load(using: account.reads)
    }
}
