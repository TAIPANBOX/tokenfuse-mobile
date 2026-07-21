import SwiftUI

/// How to order the agents list. Sorting is local because the relay sends the
/// whole list, not a page of it, so re-sorting cannot lie about what is on top.
/// The one case where it could is a truncated list, which the screen says out
/// loud rather than sorting silently within a slice.
enum AgentSort: String, CaseIterable, Identifiable, Hashable {
    case spend, burnRate, calls, runs, openExceptions, lastSeen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spend: return "Spend"
        case .burnRate: return "Burn rate"
        case .calls: return "Calls"
        case .runs: return "Runs"
        case .openExceptions: return "Open exceptions"
        case .lastSeen: return "Last seen"
        }
    }

    /// Descending on every key: the question is always "who is worst", and the
    /// answer belongs at the top.
    func sort(_ agents: [AgentRollup]) -> [AgentRollup] {
        agents.sorted { a, b in
            switch self {
            case .spend: return (a.spentMicrousd, a.agentId) > (b.spentMicrousd, b.agentId)
            case .burnRate: return (a.burnRateMicrousdPerMin, a.agentId) > (b.burnRateMicrousdPerMin, b.agentId)
            case .calls: return (a.calls, a.agentId) > (b.calls, b.agentId)
            case .runs: return (a.runs, a.agentId) > (b.runs, b.agentId)
            case .openExceptions: return (a.openExceptions, a.agentId) > (b.openExceptions, b.agentId)
            case .lastSeen: return (a.lastSeenUnix, a.agentId) > (b.lastSeenUnix, b.agentId)
            }
        }
    }
}

/// The Agents tab, fed by the relay's roll-up rather than by browsing runs.
///
/// Named `AgentsRelayView` to stand apart from the older `AgentsView`, which
/// reads Cloud's `/v1/agents` directly and belongs to a shell this app no
/// longer has. The relay-served list is bounded by construction, so this screen
/// can never become the fleet browser the design exists to avoid.
struct AgentsRelayView: View {
    let account: Account
    var onUnpair: () -> Void

    @State private var store = MoneyStore()
    @State private var sort: AgentSort = .spend

    private var agents: [AgentRollup] { sort.sort(store.agents) }

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
                    ForEach(agents) { agent in
                        NavigationLink {
                            AgentDetailView(
                                account: account,
                                agent: agent,
                                fleetSpentMicrousd: store.aggregates?.spendMicrousd ?? 0,
                                onUnpair: onUnpair
                            )
                        } label: {
                            row(agent)
                        }
                        .buttonStyle(.plain)
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
            .toolbar { sortMenu }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: store.deauthorized) { _, gone in if gone { onUnpair() } }
        }
        .tint(Palette.iris)
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(AgentSort.allCases) { key in Text(key.label).tag(key) }
                }
            } label: {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .medium))
            }
        }
    }

    private func row(_ agent: AgentRollup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.shortName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(agent.isUnattributed ? Palette.dim : Palette.fg)
                HStack(spacing: 6) {
                    Text("\(agent.calls) calls \u{00B7} \(agent.runs) runs")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.faint)
                    if agent.openExceptions > 0 {
                        Text("\(agent.openExceptions) open")
                            .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                            .foregroundStyle(Palette.iris)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Palette.iris.opacity(0.1), in: Capsule())
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "$%.2f", agent.spent))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                // The one figure here that says "right now" rather than "so
                // far", which is why it sits under the total rather than being
                // left to the detail screen.
                Text(String(format: "%.2f $/min", agent.burnRatePerMin))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(agent.burnRateMicrousdPerMin > 0 ? Palette.amber : Palette.faint)
            }
        }
        .padding(14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
    }

    /// A cut list says so, and says it differently once the order is not the
    /// order the cut was made in. The relay keeps the top spenders; sorting
    /// those by burn rate answers "the hottest of the biggest spenders", which
    /// is not the same question as "the hottest agent", and pretending
    /// otherwise is exactly the silent-truncation trap this app avoids
    /// elsewhere.
    private var truncationNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("and \(store.agentsTruncated) more, \(String(format: "$%.2f", store.othersSpent)) between them")
            if sort != .spend {
                Text("sorted within the biggest spenders the relay sent, not the whole fleet")
                    .foregroundStyle(Palette.amber)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Palette.faint)
        .padding(.top, 4)
    }

    private func load() async {
        await store.load(using: account.reads)
    }
}
