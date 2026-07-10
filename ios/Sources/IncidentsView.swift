import SwiftUI
import Observation
import UIKit

/// The fleet's aggregated anomalies (`/v1/incidents`): budget exhaustion,
/// sustained loops, spend spikes and fan-out explosions. Open (unacknowledged)
/// incidents lead, newest first; acknowledged ones trail, dimmed. Acking is a
/// signed, Face-ID-gated mutation — same gate as killing a run. A paid feature —
/// a 402 `plan_required` renders an upgrade card instead of an error.
struct IncidentsView: View {
    let account: Account

    @State private var store = IncidentsStore()
    @State private var ackTarget: Incident?
    @State private var actionError: String?

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
                    case .loaded(let incidents):
                        if incidents.isEmpty {
                            emptyState
                        } else {
                            ForEach(incidents) { incident in
                                IncidentRow(incident: incident) { ackTarget = incident }
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
                Text("Incidents").font(.system(.body, design: .monospaced)).foregroundStyle(Palette.dim)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .alert("Acknowledge this incident?", isPresented: ackAlertBinding, presenting: ackTarget) { incident in
            Button("Acknowledge") { ack(incident) }
            Button("Cancel", role: .cancel) {}
        } message: { incident in
            Text("Signed on this iPhone. \(IncidentKind.describe(incident.kind).label) won't need action again unless it recurs.")
        }
        .alert("Couldn't acknowledge the incident", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func reload() async {
        await store.load(using: client)
    }

    private var header: some View {
        Text("FLEET ANOMALIES")
            .font(.system(size: 10, weight: .semibold)).tracking(2)
            .foregroundStyle(Palette.faint)
    }

    private var loadingState: some View {
        ProgressView().tint(Palette.iris).frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var emptyState: some View {
        Text("No incidents. Your fleet is calm.")
            .font(.mono).foregroundStyle(Palette.faint)
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
    }

    private func upgradeCard(_ info: PlanRequiredError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text("INCIDENTS IS A PAID FEATURE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.faint)
            Text("Upgrade \(info.org) to see budget exhaustion, sustained loops, spend spikes and fan-out anomalies across the fleet.")
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
        .accessibilityLabel("Incidents requires a plan upgrade for \(info.org)")
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

    private var ackAlertBinding: Binding<Bool> {
        Binding(get: { ackTarget != nil }, set: { if !$0 { ackTarget = nil } })
    }
    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private func ack(_ incident: Incident) {
        Task {
            guard await Biometrics.confirm(reason: "Acknowledge \(IncidentKind.describe(incident.kind).label)") else { return }
            do {
                try await account.ackIncident(id: incident.id)
                await reload()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// Loads `/v1/incidents`: open (unacknowledged) first, each bucket newest-seen
/// first, surfacing `plan_required` as a distinct phase.
@MainActor
@Observable
final class IncidentsStore {
    enum Phase {
        case idle, loading
        case loaded([Incident])
        case planRequired(PlanRequiredError)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    func load(using client: APIClient) async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let incidents = try await client.incidents()
            phase = .loaded(incidents.sorted {
                if $0.acknowledged != $1.acknowledged { return !$0.acknowledged && $1.acknowledged }
                return $0.lastSeenMillis > $1.lastSeenMillis
            })
        } catch APIClient.ClientError.planRequired(let info) {
            phase = .planRequired(info)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Human label + SF Symbol for a detector `kind`. Unknown kinds still render —
/// the raw snake_case string, humanized, with a generic glyph.
enum IncidentKind {
    struct Presentation {
        let label: String
        let symbol: String
    }

    static func describe(_ kind: String) -> Presentation {
        switch kind {
        case "budget_exhausted":
            return Presentation(label: "Budget exhausted", symbol: "fuelpump.slash")
        case "sustained_loop":
            return Presentation(label: "Sustained loop", symbol: "arrow.triangle.2.circlepath")
        case "spend_spike":
            return Presentation(label: "Spend spike", symbol: "chart.line.uptrend.xyaxis")
        case "fanout_explosion":
            return Presentation(label: "Fan-out explosion", symbol: "arrow.triangle.branch")
        default:
            return Presentation(label: humanize(kind), symbol: "exclamationmark.triangle")
        }
    }

    private static func humanize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "Unknown" }
        let words = raw.split(separator: "_").map(String.init)
        guard let first = words.first else { return raw }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }
}

/// Severity → accent color, tolerant of unknown values.
enum IncidentSeverity {
    static func accent(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "low": return Palette.mint
        case "medium": return Palette.amber
        case "high", "critical": return Palette.ember
        default: return Palette.faint
        }
    }
}

/// One incident: kind + severity, scope (run / agent), occurrence count, last
/// seen, and — when open — an Acknowledge action.
struct IncidentRow: View {
    let incident: Incident
    var onAcknowledge: () -> Void

    private var kind: IncidentKind.Presentation { IncidentKind.describe(incident.kind) }
    private var accent: Color { IncidentSeverity.accent(incident.severity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(incident.acknowledged ? Palette.faint : accent)
                    .frame(width: 30, height: 30)
                    .background((incident.acknowledged ? Palette.faint : accent).opacity(0.1), in: Circle())
                    .overlay(Circle().stroke((incident.acknowledged ? Palette.faint : accent).opacity(0.3)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label).font(.system(size: 14, weight: .semibold))
                    Text(relativeTime(incident.lastSeenMillis))
                        .font(.mono).foregroundStyle(Palette.dim)
                }
                Spacer()
                severityPill
            }

            if incident.runId != nil || incident.agentId != nil || incident.occurrences > 1 {
                HStack(spacing: 10) {
                    if let runId = incident.runId, !runId.isEmpty {
                        Text(runId).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.dim)
                    }
                    if let agentId = incident.agentId, !agentId.isEmpty {
                        Text(agentId).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.dim)
                    }
                    if incident.occurrences > 1 {
                        Text("×\(incident.occurrences)").font(.mono).foregroundStyle(Palette.dim)
                    }
                    Spacer()
                }
            }

            if incident.acknowledged {
                ackedPill
            } else {
                Button(action: onAcknowledge) {
                    Text("Acknowledge")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(Palette.ink)
                        .background(Palette.iris, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Acknowledge \(kind.label)")
                .accessibilityHint("Signs and clears this incident on this iPhone")
            }
        }
        .padding(14)
        .background(
            (incident.acknowledged ? Palette.panel.opacity(0.4) : Palette.panel),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(incident.acknowledged ? Palette.line : accent.opacity(0.3))
        )
        .opacity(incident.acknowledged ? 0.6 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: !incident.acknowledged) {
            if !incident.acknowledged {
                Button("Acknowledge", action: onAcknowledge).tint(Palette.iris)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var severityPill: some View {
        Text(incident.severity.isEmpty ? "UNKNOWN" : incident.severity.uppercased())
            .font(.system(size: 9, weight: .semibold)).tracking(0.6)
            .foregroundStyle(accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(accent.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.35)))
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
        var parts = [kind.label, "severity \(incident.severity.isEmpty ? "unknown" : incident.severity)"]
        if let runId = incident.runId, !runId.isEmpty { parts.append("run \(runId)") }
        if let agentId = incident.agentId, !agentId.isEmpty { parts.append("agent \(agentId)") }
        if incident.occurrences > 1 { parts.append("\(incident.occurrences) occurrences") }
        parts.append(relativeTime(incident.lastSeenMillis))
        parts.append(incident.acknowledged ? "acknowledged" : "not yet acknowledged")
        return parts.joined(separator: ", ")
    }

    private func relativeTime(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
