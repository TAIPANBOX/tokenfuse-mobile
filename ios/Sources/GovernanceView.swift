import SwiftUI
import Observation
import UIKit

/// Org-level governance: the regulator evidence pack (`/v1/compliance/evidence`)
/// and the tamper-evident audit trail (`/v1/audit` + `/v1/audit/verify` +
/// `/v1/audit/manifest`), switched via a segmented control. Both are paid
/// features, gated independently, and loaded lazily per section so a failure
/// or upgrade wall in one doesn't blank the other. Read-only: no signed
/// mutations happen from this screen.
struct GovernanceView: View {
    let account: Account

    @State private var section: Section = .evidence
    @State private var evidenceStore = EvidenceStore()
    @State private var auditStore = AuditStore()
    @State private var manifestExpanded = false

    private var client: APIClient { account.reads }

    enum Section: String, CaseIterable, Hashable {
        case evidence = "Evidence"
        case audit = "Audit"
    }

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("ORG GOVERNANCE")
                        .font(.system(size: 10, weight: .semibold)).tracking(2)
                        .foregroundStyle(Palette.faint)
                    segmentedControl
                    switch section {
                    case .evidence: evidenceContent
                    case .audit: auditContent
                    }
                }
                .padding(18)
            }
        }
        .foregroundStyle(Palette.fg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Governance").font(.system(.body, design: .monospaced)).foregroundStyle(Palette.dim)
            }
        }
        .task { await loadCurrentSection() }
        .onChange(of: section) { _, _ in Task { await loadCurrentSection() } }
        .refreshable { await loadCurrentSection() }
    }

    private func loadCurrentSection() async {
        switch section {
        case .evidence: await evidenceStore.load(using: client)
        case .audit: await auditStore.load(using: client)
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

    // MARK: - Evidence

    @ViewBuilder private var evidenceContent: some View {
        switch evidenceStore.phase {
        case .idle, .loading:
            loadingState
        case .loaded(let pack):
            evidenceStatusStrip(pack)
            frameworkSection(title: "EU AI Act", controls: pack.euAiAct)
            frameworkSection(title: "SR 11-7", controls: pack.sr117)
            frameworkSection(title: "SOC 2", controls: pack.soc2)
            evidenceFooter(pack.generatedNote)
        case .planRequired(let info):
            upgradeCard(
                info, title: "EVIDENCE PACKS ARE A PAID FEATURE",
                detail: "Upgrade \(info.org) to see EU AI Act, SR 11-7 and SOC 2 evidence mapped from live org data."
            )
        case .failed(let message):
            errorCard(message) { await evidenceStore.load(using: client) }
        }
    }

    private func evidenceStatusStrip(_ pack: EvidencePackResponse) -> some View {
        let ok = pack.auditChainVerified
        let accent = ok ? Palette.mint : Palette.ember
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                Text(ok ? "CHAIN VERIFIED" : "CHAIN BROKEN AT #\(pack.auditBreakIndex.map(String.init) ?? "unknown")")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(accent)
                Spacer()
            }
            HStack(spacing: 10) {
                evidenceCounter(label: "Entries", value: pack.auditEntries)
                evidenceCounter(label: "Decisions", value: pack.decisionsTotal)
                evidenceCounter(label: "Incidents", value: pack.incidentsTotal)
            }
        }
        .padding(14)
        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.25)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ok ? "Audit chain verified" : "Audit chain broken at position \(pack.auditBreakIndex.map(String.init) ?? "unknown")")
    }

    private func evidenceCounter(label: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.instrument(20)).monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(Palette.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func frameworkSection(title: String, controls: [EvidenceControl]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(Palette.faint)
            if controls.isEmpty {
                Text("No controls mapped yet.")
                    .font(.mono).foregroundStyle(Palette.faint)
            } else {
                ForEach(controls, id: \.self) { control in
                    EvidenceControlRow(control: control)
                }
            }
        }
    }

    private func evidenceFooter(_ note: String) -> some View {
        Text(note)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.faint)
            .padding(.top, 4)
    }

    // MARK: - Audit

    @ViewBuilder private var auditContent: some View {
        switch auditStore.phase {
        case .idle, .loading:
            loadingState
        case .loaded(let entries, let verify):
            auditVerifyBanner(verify)
            auditEntriesList(entries)
            manifestCard
        case .planRequired(let info):
            upgradeCard(
                info, title: "AUDIT TRAIL IS A PAID FEATURE",
                detail: "Upgrade \(info.org) to see the tamper-evident audit trail and its signed manifest."
            )
        case .failed(let message):
            errorCard(message) { await auditStore.load(using: client) }
        }
    }

    private func auditVerifyBanner(_ verify: AuditVerifyResponse) -> some View {
        let accent = verify.ok ? Palette.mint : Palette.ember
        return HStack(spacing: 10) {
            Image(systemName: verify.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
            Text(verify.ok ? "CHAIN VERIFIED" : "BROKEN AT #\(verify.breakIndex.map(String.init) ?? "unknown")")
                .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                .foregroundStyle(accent)
            Spacer()
        }
        .padding(14)
        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.25)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(verify.ok ? "Audit chain verified" : "Audit chain broken at position \(verify.breakIndex.map(String.init) ?? "unknown")")
    }

    private func auditEntriesList(_ entries: [AuditEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT ENTRIES")
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(Palette.faint)
            if entries.isEmpty {
                Text("No audit entries yet.")
                    .font(.mono).foregroundStyle(Palette.faint)
            } else {
                ForEach(entries.prefix(50)) { entry in
                    AuditEntryRow(entry: entry)
                }
            }
        }
    }

    @ViewBuilder private var manifestCard: some View {
        switch auditStore.manifestPhase {
        case .idle, .loading, .planRequired, .failed:
            EmptyView()
        case .unavailable:
            Text("No signing key configured on this plane; the signed manifest isn't available.")
                .font(.mono).foregroundStyle(Palette.faint)
        case .loaded(let manifest):
            manifestDisclosure(manifest)
        }
    }

    private func manifestDisclosure(_ manifest: AuditManifest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { manifestExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "signature")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.iris)
                    Text("SIGNED MANIFEST")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                        .foregroundStyle(Palette.faint)
                    Spacer()
                    Image(systemName: manifestExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.dim)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Signed manifest")
            .accessibilityHint(manifestExpanded ? "Double tap to collapse" : "Double tap to expand")

            if manifestExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    manifestRow(label: "Org", value: manifest.org)
                    manifestRow(label: "Tip seq", value: "\(manifest.tipSeq)")
                    manifestRow(label: "Entries", value: "\(manifest.entryCount)")
                    manifestRow(label: "Algorithm", value: manifest.algorithm)
                    manifestRow(label: "Signature", value: manifest.signatureB64.truncatedHash)
                    manifestRow(label: "Public key", value: manifest.publicKeyB64.truncatedHash)
                    Text("Reference only: an auditor re-derives and verifies this offline. The app takes no action on it.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.faint)
                        .padding(.top, 4)
                }
                .padding(.top, 12)
            }
        }
        .padding(14)
        .background(Palette.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
    }

    private func manifestRow(label: String, value: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(Palette.faint)
            Spacer()
            Text(value).font(.system(.footnote, design: .monospaced)).foregroundStyle(Palette.dim)
        }
    }

    // MARK: - Shared states

    private var loadingState: some View {
        ProgressView().tint(Palette.iris).frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func upgradeCard(_ info: PlanRequiredError, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text(title)
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.faint)
            Text(detail)
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
        .accessibilityLabel("\(title.capitalized) for \(info.org)")
    }

    private func errorCard(_ message: String, retry: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAN'T REACH THE PLANE").font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.ember)
            Text(message).font(.mono).foregroundStyle(Palette.dim)
            Button("Retry") { Task { await retry() } }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.iris)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ember.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.ember.opacity(0.3)))
    }
}

// MARK: - Rows

/// One control's status inside a regulator evidence-pack framework section.
struct EvidenceControlRow: View {
    let control: EvidenceControl

    private var accent: Color {
        switch control.status {
        case .enforced: return Palette.mint
        case .partial: return Palette.amber
        case .documented: return Palette.faint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(control.control)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Spacer()
                statusPill
            }
            Text(control.evidence)
                .font(.mono).foregroundStyle(Palette.dim)
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(control.control), \(control.status.rawValue), evidence \(control.evidence)")
    }

    private var statusPill: some View {
        Text(control.status.rawValue.uppercased())
            .font(.system(size: 9, weight: .semibold)).tracking(0.6)
            .foregroundStyle(accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(accent.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.35)))
    }
}

/// One entry in the org's tamper-evident audit trail: who did what to what,
/// when, plus the hash link to the previous entry (truncated, monospaced).
struct AuditEntryRow: View {
    let entry: AuditEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(entry.seq)").font(.system(.callout, design: .monospaced)).foregroundStyle(Palette.dim)
                Text(entry.action).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(relativeTime(entry.tsMillis)).font(.mono).foregroundStyle(Palette.dim)
            }
            HStack(spacing: 8) {
                Text(entry.actor).font(.mono).foregroundStyle(Palette.dim)
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Palette.faint)
                Text(entry.subject).font(.mono).foregroundStyle(Palette.dim)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Palette.faint)
                Text("\(entry.prevHash.truncatedHash) → \(entry.entryHash.truncatedHash)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.faint)
            }
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Entry \(entry.seq), \(entry.action) by \(entry.actor) on \(entry.subject), \(relativeTime(entry.tsMillis))")
    }

    private func relativeTime(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Formatting helpers

extension String {
    /// Truncates a long hex/base64 string for display: first 8 chars, an
    /// ellipsis, last 8 chars. Short strings pass through unchanged.
    var truncatedHash: String {
        guard count > 20 else { return self }
        return "\(prefix(8))…\(suffix(8))"
    }
}

// MARK: - Stores

/// Loads `/v1/compliance/evidence`, surfacing `plan_required` as a distinct
/// phase so the view can render an upgrade CTA rather than an error.
@MainActor
@Observable
final class EvidenceStore {
    enum Phase {
        case idle, loading
        case loaded(EvidencePackResponse)
        case planRequired(PlanRequiredError)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    func load(using client: APIClient) async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let pack = try await client.complianceEvidence()
            phase = .loaded(pack)
        } catch APIClient.ClientError.planRequired(let info) {
            phase = .planRequired(info)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Loads `/v1/audit` + `/v1/audit/verify` together (main phase), and
/// `/v1/audit/manifest` independently (manifest phase) — a 404 there means no
/// signing key is configured on the plane, which isn't an error worth
/// blanking the audit list for.
@MainActor
@Observable
final class AuditStore {
    enum Phase {
        case idle, loading
        case loaded([AuditEntry], AuditVerifyResponse)
        case planRequired(PlanRequiredError)
        case failed(String)
    }

    enum ManifestPhase {
        case idle, loading
        case loaded(AuditManifest)
        /// No signing key configured on the plane (404).
        case unavailable
        case planRequired(PlanRequiredError)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var manifestPhase: ManifestPhase = .idle

    func load(using client: APIClient) async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            async let entriesTask = client.audit()
            async let verifyTask = client.auditVerify()
            let (entries, verify) = try await (entriesTask, verifyTask)
            phase = .loaded(entries.sorted { $0.seq > $1.seq }, verify)
        } catch APIClient.ClientError.planRequired(let info) {
            phase = .planRequired(info)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        await loadManifest(using: client)
    }

    private func loadManifest(using client: APIClient) async {
        if case .loaded = manifestPhase {} else { manifestPhase = .loading }
        do {
            let manifest = try await client.auditManifest()
            manifestPhase = .loaded(manifest)
        } catch APIClient.ClientError.planRequired(let info) {
            manifestPhase = .planRequired(info)
        } catch APIClient.ClientError.http(404) {
            manifestPhase = .unavailable
        } catch {
            manifestPhase = .failed(error.localizedDescription)
        }
    }
}
