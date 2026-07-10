import SwiftUI
import Observation
import UIKit

/// Per-run replay (`/v1/replay/{run}`): the run's agent-event timeline joined
/// with its incidents and referencing audit entries. Read-only, for
/// after-the-fact review. If the plane hasn't turned on event capture
/// (`TOKENFUSE_CLOUD_REPLAY_EVENTS`), `configured` comes back `false` and this
/// renders an explanatory empty state instead of an empty timeline. A paid
/// feature — a 402 `plan_required` renders an upgrade card instead of an error.
struct ReplayView: View {
    let run: String
    let account: Account

    @State private var store = ReplayStore()

    private var client: APIClient { account.reads }

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch store.phase {
                    case .idle, .loading:
                        loadingState
                    case .loaded(let replay):
                        if replay.configured {
                            content(replay)
                        } else {
                            notConfiguredState
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
                Text("Replay · \(run)").font(.system(.body, design: .monospaced)).foregroundStyle(Palette.dim)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        await store.load(run: run, using: client)
    }

    // MARK: - Loaded, configured

    @ViewBuilder private func content(_ replay: ReplayResponse) -> some View {
        eventCountHeader(replay.eventCount)
        if replay.events.isEmpty {
            emptyEventsState
        } else {
            timelineSection(replay.events)
        }
        if !replay.incidents.isEmpty {
            incidentsSection(replay.incidents)
        }
        if !replay.audit.isEmpty {
            auditSection(replay.audit)
        }
        if replay.malformedSkipped > 0 {
            footnote(replay.malformedSkipped)
        }
    }

    private func eventCountHeader(_ count: Int) -> some View {
        Text("\(count) EVENT\(count == 1 ? "" : "S")")
            .font(.system(size: 10, weight: .semibold)).tracking(2)
            .foregroundStyle(Palette.faint)
    }

    private var emptyEventsState: some View {
        Text("No events recorded for this run yet.")
            .font(.mono).foregroundStyle(Palette.faint)
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 20)
    }

    private func timelineSection(_ events: [ReplayEvent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TIMELINE")
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(Palette.faint)
                .padding(.bottom, 10)
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                ReplayEventRow(event: event)
            }
        }
    }

    private func incidentsSection(_ incidents: [Incident]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INCIDENTS")
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(Palette.faint)
            ForEach(incidents) { incident in
                CompactIncidentRow(incident: incident)
            }
        }
    }

    private func auditSection(_ entries: [AuditEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REFERENCING AUDIT ENTRIES")
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(Palette.faint)
            ForEach(entries) { entry in
                AuditEntryRow(entry: entry)
            }
        }
    }

    private func footnote(_ skipped: Int) -> some View {
        Text("\(skipped) malformed event\(skipped == 1 ? "" : "s") skipped.")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.faint)
    }

    // MARK: - Not configured

    private var notConfiguredState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.faint)
            Text("REPLAY ISN'T ENABLED ON THIS PLANE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.faint)
            Text("The operator hasn't turned on agent-event capture (server env TOKENFUSE_CLOUD_REPLAY_EVENTS). Ask them to enable it to see this run's timeline.")
                .font(.mono).foregroundStyle(Palette.dim)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replay isn't enabled on this plane")
    }

    // MARK: - Shared states

    private var loadingState: some View {
        ProgressView().tint(Palette.iris).frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func upgradeCard(_ info: PlanRequiredError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text("REPLAY IS A PAID FEATURE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.faint)
            Text("Upgrade \(info.org) to see this run's agent-event timeline, incidents and audit trail.")
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
        .accessibilityLabel("Replay requires a plan upgrade for \(info.org)")
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

// MARK: - Rows

/// One replayed agent event: type + severity, source/agent, relative time,
/// and a compact preview of `data` (a handful of key/values, not a raw dump).
struct ReplayEventRow: View {
    let event: ReplayEvent

    private var accent: Color { IncidentSeverity.accent(event.severity ?? "") }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(accent).frame(width: 8, height: 8).padding(.top, 5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(event.type ?? "event").font(.system(size: 13, weight: .semibold))
                    if let severity = event.severity, !severity.isEmpty {
                        severityPill(severity)
                    }
                    Spacer()
                    Text(displayTime).font(.mono).foregroundStyle(Palette.dim)
                }
                HStack(spacing: 8) {
                    if let source = event.source, !source.isEmpty {
                        Text(source).font(.mono).foregroundStyle(Palette.dim)
                    }
                    if let agentId = event.agentId, !agentId.isEmpty {
                        Text(agentId).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.iris)
                    }
                    Spacer()
                }
                if let data = event.data, !data.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(compactData(data), id: \.0) { pair in
                            Text("\(pair.0): \(pair.1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.faint)
                        }
                    }
                }
            }
            .padding(.bottom, 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func severityPill(_ severity: String) -> some View {
        Text(severity.uppercased())
            .font(.system(size: 9, weight: .semibold)).tracking(0.6)
            .foregroundStyle(accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(accent.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.35)))
    }

    /// Up to four `data` fields, sorted by key, rendered as short strings.
    private func compactData(_ data: [String: JSONValue]) -> [(String, String)] {
        data.sorted { $0.key < $1.key }.prefix(4).map { ($0.key, $0.value.compactDisplay) }
    }

    private var displayTime: String {
        guard let ts = event.ts else { return "no timestamp" }
        if let date = ISO8601DateFormatter().date(from: ts) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return ts
    }

    private var accessibilityText: String {
        var parts = [event.type ?? "event"]
        if let source = event.source, !source.isEmpty { parts.append("from \(source)") }
        if let severity = event.severity, !severity.isEmpty { parts.append("severity \(severity)") }
        if let agentId = event.agentId, !agentId.isEmpty { parts.append("agent \(agentId)") }
        parts.append(displayTime)
        return parts.joined(separator: ", ")
    }
}

/// A compact incident row for embedding in replay (no acknowledge action —
/// this screen is read-only).
struct CompactIncidentRow: View {
    let incident: Incident

    private var kind: IncidentKind.Presentation { IncidentKind.describe(incident.kind) }
    private var accent: Color { IncidentSeverity.accent(incident.severity) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(accent.opacity(0.1), in: Circle())
                .overlay(Circle().stroke(accent.opacity(0.3)))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label).font(.system(size: 13, weight: .semibold))
                Text(relativeTime(incident.lastSeenMillis)).font(.mono).foregroundStyle(Palette.dim)
            }
            Spacer()
            if incident.acknowledged {
                ackedPill
            }
        }
        .padding(12)
        .background(Palette.panel.opacity(incident.acknowledged ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(incident.acknowledged ? Palette.line : accent.opacity(0.3)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var ackedPill: some View {
        Text("ACKED")
            .font(.system(size: 9, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Palette.mint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Palette.mint.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(Palette.mint.opacity(0.3)))
    }

    private var accessibilityText: String {
        var parts = [kind.label, relativeTime(incident.lastSeenMillis)]
        if incident.acknowledged { parts.append("acknowledged") }
        return parts.joined(separator: ", ")
    }

    private func relativeTime(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Formatting helpers

extension JSONValue {
    /// A short, human-scannable rendering for the compact event preview —
    /// never a raw JSON dump.
    var compactDisplay: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[\(a.count) item\(a.count == 1 ? "" : "s")]"
        case .object(let o): return "{\(o.count) field\(o.count == 1 ? "" : "s")}"
        }
    }
}

// MARK: - Store

/// Loads `/v1/replay/{run}`, surfacing `plan_required` as a distinct phase so
/// the view can render an upgrade CTA rather than an error.
@MainActor
@Observable
final class ReplayStore {
    enum Phase {
        case idle, loading
        case loaded(ReplayResponse)
        case planRequired(PlanRequiredError)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    func load(run: String, using client: APIClient) async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let replay = try await client.replay(run: run)
            phase = .loaded(replay)
        } catch APIClient.ClientError.planRequired(let info) {
            phase = .planRequired(info)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
