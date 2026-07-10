import SwiftUI
import Observation
import UIKit

/// Per-agent spend breakdown (`/v1/agents`), highest spend first. The empty
/// `agentId` is the explicit "unattributed" bucket — calls the gateway
/// couldn't tag to a logical agent. A paid feature — a 402 `plan_required`
/// renders an upgrade card instead of an error.
struct AgentsView: View {
    let account: Account

    @State private var store = AgentsStore()

    private var client: APIClient { account.reads }

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    switch store.phase {
                    case .idle, .loading:
                        loadingState
                    case .loaded(let agents):
                        if agents.isEmpty {
                            emptyState
                        } else {
                            ForEach(agents) { agent in
                                AgentRow(agent: agent)
                            }
                        }
                    case .planRequired(let info):
                        upgradeCard(info)
                    case .failed(let message):
                        errorCard(message)
                    }
                }
                .padding(18)
            }
        }
        .foregroundStyle(Palette.fg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Agents").font(.system(.body, design: .monospaced)).foregroundStyle(Palette.dim)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        await store.load(using: client)
    }

    private var header: some View {
        Text("SPEND BY AGENT")
            .font(.system(size: 10, weight: .semibold)).tracking(2)
            .foregroundStyle(Palette.faint)
    }

    private var loadingState: some View {
        ProgressView().tint(Palette.iris).frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var emptyState: some View {
        Text("No attributed spend yet. Tag calls with an agent id at the gateway and they'll appear here.")
            .font(.mono).foregroundStyle(Palette.faint)
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
    }

    private func upgradeCard(_ info: PlanRequiredError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text("AGENT BREAKDOWN IS A PAID FEATURE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.faint)
            Text("Upgrade \(info.org) to see per-agent spend, calls and runs.")
                .font(.mono).foregroundStyle(Palette.dim)
            Button {
                if let url = URL(string: info.upgradeUrl) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Upgrade")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(Palette.ink)
                    .background(Palette.amber, in: Capsule())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.amber.opacity(0.3)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent breakdown requires a plan upgrade for \(info.org)")
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAN'T REACH THE PLANE").font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.ember)
            Text(message).font(.mono).foregroundStyle(Palette.dim)
            Button("Retry") { Task { await reload() } }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.iris)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ember.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.ember.opacity(0.3)))
    }
}

/// One agent's spend rollup: id (or "unattributed"), spend, calls, runs.
struct AgentRow: View {
    let agent: AgentAgg

    private var isUnattributed: Bool { agent.agentId.isEmpty }
    private var displayId: String { isUnattributed ? "unattributed" : agent.agentId }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isUnattributed ? "questionmark.circle" : "cpu")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isUnattributed ? Palette.faint : Palette.iris)
                .frame(width: 30, height: 30)
                .background((isUnattributed ? Palette.faint : Palette.iris).opacity(0.1), in: Circle())
                .overlay(Circle().stroke((isUnattributed ? Palette.faint : Palette.iris).opacity(0.3)))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayId)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(isUnattributed ? Palette.faint : Palette.fg)
                Text("\(agent.calls) call\(agent.calls == 1 ? "" : "s") · \(agent.runs) run\(agent.runs == 1 ? "" : "s")")
                    .font(.mono).foregroundStyle(Palette.dim)
            }
            Spacer()
            Text("$\(String(format: "%.2f", agent.spent))")
                .font(.instrument(18)).monospacedDigit()
                .foregroundStyle(isUnattributed ? Palette.dim : Palette.fg)
        }
        .padding(14)
        .background(Palette.panel.opacity(isUnattributed ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        "\(isUnattributed ? "Unattributed" : "Agent \(agent.agentId)"), spent \(String(format: "$%.2f", agent.spent)), \(agent.calls) calls, \(agent.runs) runs"
    }
}

/// Loads `/v1/agents`, sorted by spend descending (don't rely on server
/// ordering), surfacing `plan_required` as a distinct phase.
@MainActor
@Observable
final class AgentsStore {
    enum Phase {
        case idle, loading
        case loaded([AgentAgg])
        case planRequired(PlanRequiredError)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    func load(using client: APIClient) async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let agents = try await client.agents()
            phase = .loaded(agents.sorted { $0.spentMicrousd > $1.spentMicrousd })
        } catch APIClient.ClientError.planRequired(let info) {
            phase = .planRequired(info)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
