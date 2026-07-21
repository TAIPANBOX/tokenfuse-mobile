import SwiftUI

/// Everything known about one agent, which is the screen that makes a kill
/// defensible.
///
/// The list answers "who is worst". This answers "what is this one doing", and
/// it puts the two axes next to each other on purpose: cost on the left of the
/// decision, conduct on the right. Killing a run because it is expensive is a
/// guess; killing it because it is expensive AND has an open detection is a
/// decision, and the audit trail then records the second one.
///
/// Bounded by construction: one agent's figures come from the money roll-up
/// already in hand, and its open rows are the queue filtered locally. Nothing
/// here asks the relay for anything it does not already serve.
struct AgentDetailView: View {
    let account: Account
    let agent: AgentRollup
    /// The fleet's own spend, so this agent's share can be stated rather than
    /// left for the reader to divide in their head.
    let fleetSpentMicrousd: Int64
    var onUnpair: () -> Void

    @State private var store = ExceptionQueueStore()
    @State private var killTarget: ExceptionItem?
    @State private var actionError: String?

    private var rows: [ExceptionItem] {
        store.queue.filter { $0.agentId == agent.agentId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                figures
                behaviour
                queueSection
            }
            .padding(18)
        }
        .background(Palette.ink.ignoresSafeArea())
        .navigationTitle(agent.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: store.deauthorized) { _, gone in if gone { onUnpair() } }
        .alert("Kill run \(killTarget?.runId ?? "")?", isPresented: killAlertBinding, presenting: killTarget) { item in
            Button("Kill", role: .destructive) { kill(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Signed on this iPhone and enforced across every gateway.")
        }
        .alert("Couldn't complete that action", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - money

    private var figures: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StatTile(label: "Burn rate", value: String(format: "%.2f $/min", agent.burnRatePerMin))
                StatTile(label: "Spent", value: String(format: "$%.2f", agent.spent))
            }
            HStack(spacing: 10) {
                StatTile(label: "Calls", value: "\(agent.calls)")
                StatTile(label: "Runs", value: "\(agent.runs)")
            }
            if fleetSpentMicrousd > 0 {
                let share = Double(agent.spentMicrousd) / Double(fleetSpentMicrousd) * 100
                Text(String(format: "%.1f%% of everything the fleet has spent", share))
                    .font(.mono).foregroundStyle(Palette.dim)
            }
            if agent.isUnattributed {
                Text("Calls that arrived without an agent tag. Unattributed spend is still spend, which is why it is shown rather than hidden.")
                    .font(.system(size: 12)).foregroundStyle(Palette.faint)
            }
        }
    }

    // MARK: - behaviour

    @ViewBuilder private var behaviour: some View {
        if agent.openExceptions > 0 {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(Palette.iris)
                Text("\(agent.openExceptions) open, worst \(agent.worstSeverity ?? "unrated")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(12)
            .background(Palette.iris.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.iris.opacity(0.3)))
        }
    }

    // MARK: - what it is doing right now

    @ViewBuilder private var queueSection: some View {
        Text("ON THE QUEUE")
            .font(.system(size: 10, weight: .semibold)).tracking(1.6)
            .foregroundStyle(Palette.faint)
        if rows.isEmpty {
            Text(store.phase == .loading ? "Checking\u{2026}" : "Nothing from this agent needs a decision.")
                .font(.system(size: 13)).foregroundStyle(Palette.dim)
        } else {
            ForEach(rows) { item in
                ExceptionRow(item: item, onKill: { killTarget = item }, onAcknowledge: {})
            }
        }
    }

    // MARK: - actions

    /// The same ceremony the queue performs, deliberately: a confirmation that
    /// names the run, then Face ID, then a signature made on this device. A
    /// second, softer path to the same irreversible thing is how a product ends
    /// up with two ceremonies and one of them wrong.
    private func kill(_ item: ExceptionItem) {
        guard let runId = item.runId else { return }
        Task {
            guard await Biometrics.confirm(reason: "Kill run \(runId)") else { return }
            do {
                try await account.kill(run: runId)
                await reload() // confirm from data, not optimistically
            } catch APIClient.ClientError.http(401) {
                onUnpair()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func reload() async { await store.load(using: account.reads) }

    private var killAlertBinding: Binding<Bool> {
        Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } })
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }
}
