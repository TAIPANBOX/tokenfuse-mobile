import SwiftUI

/// The relay-paired home screen (docs/PHASE5.md W3 "exception-queue screen",
/// itrat-console/13 D12.2b step 5): the phone's ENTIRE view of the fleet is
/// this bounded, pre-computed slice, aggregates plus only at-risk / near-cap /
/// over-cap / runaway / pending-approval items, never the full run list. The
/// relay's W1 read-proxy allowlists exactly `/v1/summary` +
/// `/relay/v1/exceptions` (`proxy.rs`), so there is no route to browse the
/// fleet even if this screen wanted to. Empty queue = calm = normal.
struct ExceptionQueueView: View {
    let account: Account
    var onUnpair: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ExceptionQueueStore()
    @State private var killTarget: ExceptionItem?
    @State private var ackTarget: ExceptionItem?
    @State private var actionError: String?
    @State private var showSettings = false

    /// Short poll interval (docs/PHASE5.md: "POLL on a short interval + on
    /// foreground, no APNs in sim") - the relay's own SSE-driven engine
    /// updates on a 500ms tick internally (`exceptions.rs::run_event_loop`),
    /// this is how often the phone asks it for the current snapshot.
    private static let pollInterval: Duration = .seconds(5)

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if case .failed(let message) = store.phase, store.aggregates == nil {
                        errorCard(message)
                    }
                    if let aggregates = store.aggregates {
                        heroCard(aggregates)
                    }
                    queueSection
                    digestSection
                }
                .padding(18)
            }
        }
        .foregroundStyle(Palette.fg)
        .task {
            await reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { break }
                await reload()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .onChange(of: store.deauthorized) { _, gone in
            // The relay revoked this device (Disconnect / re-pair elsewhere):
            // drop the dead session and fall back to the Connect screen.
            if gone { onUnpair() }
        }
        .refreshable { await reload() }
        .alert("Kill run \(killTarget?.runId ?? "")?", isPresented: killAlertBinding, presenting: killTarget) { item in
            Button("Kill", role: .destructive) { kill(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Signed on this iPhone and enforced across every gateway.")
        }
        .alert("Acknowledge this exception?", isPresented: ackAlertBinding, presenting: ackTarget) { item in
            Button("Acknowledge") { acknowledge(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Signed on this iPhone. \(item.headline) won't need action again unless it recurs.")
        }
        .alert("Couldn't complete that action", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .sheet(isPresented: $showSettings) {
            DeviceSettingsSheet(account: account, onUnpair: onUnpair)
        }
    }

    private func reload() async {
        await store.load(using: account.reads)
    }

    private func kill(_ item: ExceptionItem) {
        guard let runId = item.runId else { return }
        Task {
            guard await Biometrics.confirm(reason: "Kill run \(runId)") else { return }
            do {
                try await account.kill(run: runId)
                await reload() // confirm from data, not optimistically
            } catch APIClient.ClientError.http(401) {
                onUnpair() // device was revoked mid-action - back to Connect
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func acknowledge(_ item: ExceptionItem) {
        guard let incidentId = item.incidentId else { return }
        Task {
            guard await Biometrics.confirm(reason: "Acknowledge \(item.headline)") else { return }
            do {
                try await account.ackIncident(id: incidentId)
                await reload() // confirm from data, not optimistically
            } catch APIClient.ClientError.http(401) {
                onUnpair() // device was revoked mid-action - back to Connect
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Exceptions").font(.instrument(32))
                HStack(spacing: 7) {
                    Circle().fill(store.phase == .loaded ? Palette.mint : Palette.faint)
                        .frame(width: 6, height: 6)
                    Text("\(account.session.org) · \(account.reads.baseURL.host() ?? "relay")")
                        .font(.mono).foregroundStyle(Palette.dim)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Palette.panel, in: Capsule())
                .overlay(Capsule().stroke(Palette.line))
            }
            Spacer()
            headerButton(icon: "gearshape", accessibilityLabel: "Settings") {
                showSettings = true
            }
        }
    }

    private func headerButton(icon: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.iris)
                .padding(9)
                .background(Palette.panel, in: Circle())
                .overlay(Circle().stroke(Palette.line))
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func heroCard(_ aggregates: ExceptionAggregates) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BURN RATE")
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(Palette.faint)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.2f", aggregates.burnRatePerMin))
                    .font(.instrument(46)).monospacedDigit()
                Text("$/min").font(.mono).foregroundStyle(Palette.amber)
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Burn rate \(String(format: "%.2f", aggregates.burnRatePerMin)) dollars per minute")
            HStack(spacing: 9) {
                StatTile(label: "Spent", value: usd(aggregates.spend))
                StatTile(label: "Headroom", value: usd(aggregates.headroom))
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAN'T REACH THE RELAY").font(.system(size: 10, weight: .semibold)).tracking(1.6)
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

    @ViewBuilder private var queueSection: some View {
        if store.queue.isEmpty {
            switch store.phase {
            case .idle, .loading:
                ProgressView().tint(Palette.iris).frame(maxWidth: .infinity).padding(.top, 40)
            case .loaded:
                allClearState
            case .failed:
                EmptyView() // errorCard above already covers this case
            }
        } else {
            queueList
        }
    }

    private var queueList: some View {
        VStack(spacing: 10) {
            ForEach(store.queue) { item in
                ExceptionRow(
                    item: item,
                    onKill: { killTarget = item },
                    onAcknowledge: { ackTarget = item }
                )
            }
            if store.queueTruncated > 0 {
                truncationNotice
            }
        }
    }

    /// Only ever shown when the relay had to cut the actionable list, which is
    /// not a normal case. Saying nothing here would mean the screen quietly
    /// claims to be the whole picture when it is not.
    private var truncationNotice: some View {
        Text("\(store.queueTruncated) more need attention than fit here. Open Genaryx to see them all.")
            .font(.mono).foregroundStyle(Palette.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.ember.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    /// What the guardrails already stopped, counted rather than listed.
    ///
    /// This is deliberately below the actionable queue and visually quieter:
    /// nothing here needs the operator to do anything, the breaker already
    /// fired. It exists because "171 runs of this agent hit their ceiling" is
    /// the sentence that shows governance working at scale, and listing those
    /// 171 individually would bury the handful of runs that DO need a decision.
    @ViewBuilder private var digestSection: some View {
        if !store.digest.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("ALREADY STOPPED")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                    .foregroundStyle(Palette.faint)
                ForEach(store.digest) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.presentation.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.mint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.agentShortName ?? row.presentation.label)
                                .font(.system(size: 14, weight: .medium))
                            Text("\(row.count) \(row.count == 1 ? "run" : "runs") · \(row.presentation.label.lowercased())")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.faint)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.mint.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }

    private var allClearState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Palette.mint)
            Text("All clear").font(.system(size: 17, weight: .semibold))
            Text("No exceptions. Every run is inside its budget.")
                .font(.mono).foregroundStyle(Palette.faint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
        .accessibilityElement(children: .combine)
    }

    private var killAlertBinding: Binding<Bool> {
        Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } })
    }
    private var ackAlertBinding: Binding<Bool> {
        Binding(get: { ackTarget != nil }, set: { if !$0 { ackTarget = nil } })
    }
    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
}

/// Loads `GET /relay/v1/exceptions`. Keeps the last-known-good snapshot on a
/// transient poll failure (only surfaces an error when there's nothing yet
/// to show) - the same "estimate-then-settle" honesty `RunsStore` already
/// uses for its own cache.
@MainActor
@Observable
final class ExceptionQueueStore {
    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var aggregates: ExceptionAggregates?
    private(set) var queue: [ExceptionItem] = []
    /// Already-contained events, counted by (kind, agent). Never empty-checked
    /// by the view for correctness, only for whether to draw the section.
    private(set) var digest: [ExceptionDigestRow] = []
    /// Nonzero only when the relay had to cut the actionable list.
    private(set) var queueTruncated: Int = 0
    /// Set when the relay rejects our device token (HTTP 401): the device was
    /// disconnected/revoked server-side - the desktop's Disconnect button
    /// (`admin::disconnect`), or another phone re-pairing into the single
    /// device slot. The view returns to the Connect screen instead of silently
    /// showing a frozen last-known-good queue behind a green "connected" dot.
    /// A TRANSIENT failure (network drop, 5xx) is deliberately NOT this: it
    /// keeps the last-known-good snapshot unchanged, exactly as before.
    private(set) var deauthorized = false

    func load(using client: APIClient) async {
        if aggregates == nil, phase != .loaded { phase = .loading }
        do {
            let snapshot = try await client.exceptions()
            aggregates = snapshot.aggregates
            queue = snapshot.queue
            digest = snapshot.digest
            queueTruncated = snapshot.queueTruncated
            phase = .loaded
        } catch APIClient.ClientError.http(401) {
            deauthorized = true
        } catch {
            if aggregates == nil {
                phase = .failed(error.localizedDescription)
            }
            // else: keep showing the last-known-good snapshot.
        }
    }
}

/// One exception: class + headline, the run's fuse when budget data is
/// available, and ONE action - kill (run-scoped) or acknowledge
/// (incident-only, no attributable run). An already-killed item shows a
/// status pill instead of an action, matching `RunRow`'s treatment.
struct ExceptionRow: View {
    let item: ExceptionItem
    var onKill: () -> Void
    var onAcknowledge: () -> Void

    private var accent: Color { item.killed ? Palette.faint : item.class.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: item.class.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 30, height: 30)
                    .background(accent.opacity(0.1), in: Circle())
                    .overlay(Circle().stroke(accent.opacity(0.3)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.headline).font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        if let runId = item.runId {
                            Text(runId).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.dim)
                        }
                        Text(relativeTime(item.lastSeenUnix)).font(.mono).foregroundStyle(Palette.dim)
                    }
                }
                Spacer()
                classPill
            }

            if let fraction = item.fraction, let budget = item.budget {
                Fuse(fraction: fraction)
                HStack {
                    Text("spent \(usd(item.spent))")
                    Spacer()
                    Text("cap \(usd(budget))")
                }
                .font(.mono).foregroundStyle(Palette.dim)
            }

            if let copilot = item.copilot {
                felyxAnnotation(copilot)
            }

            actionRow
        }
        .padding(14)
        .background(
            item.class.isHard && !item.killed
                ? AnyShapeStyle(Palette.ember.opacity(0.06))
                : AnyShapeStyle(Palette.panel),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(item.killed ? Palette.line : accent.opacity(0.3))
        )
        .opacity(item.killed ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The C3 payoff (docs/PHASE6-C3.md C3-W2): "a small optional mobile
    /// render shows the annotation". Deliberately quiet - a sparkles glyph +
    /// the one-line summary in `Palette.dim` (the same treatment as the run
    /// id / timestamp / spent-cap row above it), with `Palette.iris` (the
    /// existing "calm system" accent already used for Acknowledge and
    /// Settings, distinct from the amber/ember heat colors) reserved for the
    /// sparkles glyph and the recommended-action chip, so it never competes
    /// with the headline or the class pill for attention. Skip-graceful:
    /// this whole view only appears when `item.copilot` decoded to non-nil.
    private func felyxAnnotation(_ copilot: CopilotAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.iris)
                Text(copilot.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.dim)
            }
            if let action = copilot.recommendedAction {
                Text("suggests: \(action.kind) \(action.target)")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(Palette.iris)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.iris.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(Palette.iris.opacity(0.35)))
            }
        }
    }

    private var classPill: some View {
        Text(item.class.label.uppercased())
            .font(.system(size: 9, weight: .semibold)).tracking(0.6)
            .foregroundStyle(accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(accent.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.35)))
    }

    @ViewBuilder private var actionRow: some View {
        if item.killed {
            statusPill(text: "killed", color: Palette.faint)
        } else if item.runId != nil {
            actionButton(title: "Kill", color: Palette.ember, action: onKill)
                .accessibilityHint("Signs and sends a kill for this run from this iPhone")
        } else if item.incidentId != nil {
            actionButton(title: "Acknowledge", color: Palette.iris, action: onAcknowledge)
                .accessibilityHint("Signs and acknowledges this exception from this iPhone")
        }
    }

    private func actionButton(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(Palette.ink)
                .background(color, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold)).tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.3)))
    }

    private var accessibilityText: String {
        var parts = [item.class.label, item.headline]
        if let runId = item.runId { parts.append("run \(runId)") }
        parts.append("spent \(String(format: "$%.2f", item.spent))")
        if let budget = item.budget { parts.append("of \(String(format: "$%.2f", budget))") }
        parts.append(item.killed ? "killed" : "not yet resolved")
        if let copilot = item.copilot {
            // The row collapses into ONE accessibility element
            // (`.accessibilityElement(children: .ignore)` below), so
            // `felyxAnnotation`'s own text is otherwise unreachable by
            // VoiceOver - fold it in here instead of labeling it separately.
            parts.append("Felyx: \(copilot.summary)")
            if let action = copilot.recommendedAction {
                parts.append("suggests \(action.kind) \(action.target)")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func usd(_ value: Double) -> String { String(format: "$%.2f", value) }

    private func relativeTime(_ unixSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
