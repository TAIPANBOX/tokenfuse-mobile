import SwiftUI
import Observation
import UIKit

/// The FinOps headline: total avoided spend this month, broken down by the
/// three savings dimensions (budget-protection, semantic cache, model router).
/// Savings is a paid feature — a 402 `plan_required` renders an upgrade card
/// instead of an error.
struct SavingsView: View {
    let account: Account

    @State private var store = SavingsStore()

    private var client: APIClient { account.reads }

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch store.phase {
                    case .idle, .loading:
                        loadingState
                    case .loaded(let summary):
                        hero(summary)
                        breakdown(summary)
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
                Text("Savings").font(.system(.body, design: .monospaced)).foregroundStyle(Palette.dim)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        await store.load(using: client)
    }

    // MARK: - Loaded

    private func hero(_ summary: SavingsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVED THIS MONTH")
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(Palette.faint)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(usd(summary.totalSaved))
                    .font(.instrument(46)).monospacedDigit()
                    .foregroundStyle(Palette.mint)
                Spacer()
                Image(systemName: "shield.checkerboard")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.mint.opacity(0.6))
            }
            Text("Avoided spend across blocked runs, cache hits and model routing.")
                .font(.mono).foregroundStyle(Palette.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved this month, \(usd(summary.totalSaved))")
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.mint.opacity(0.25)))
    }

    private func breakdown(_ summary: SavingsSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BREAKDOWN")
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(Palette.faint)

            savingsRow(
                icon: "shield.lefthalf.filled",
                title: "Blocked",
                subtitle: "Runaway spend stopped by budget caps",
                amount: summary.blockedSpend,
                accent: Palette.ember
            )
            savingsRow(
                icon: "arrow.triangle.2.circlepath",
                title: "Cache",
                subtitle: "Avoided by the semantic cache",
                amount: summary.cacheSaved,
                accent: Palette.iris
            )
            savingsRow(
                icon: "arrow.branch",
                title: "Router",
                subtitle: "Avoided by routing to a cheaper model",
                amount: summary.routerSaved,
                accent: Palette.amber
            )

            budgetBreaksRow(summary.budgetBreaks)
        }
    }

    private func savingsRow(icon: String, title: String, subtitle: String, amount: Double, accent: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.1), in: Circle())
                .overlay(Circle().stroke(accent.opacity(0.3)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.mono).foregroundStyle(Palette.dim)
            }
            Spacer()
            Text(usd(amount))
                .font(.instrument(18)).monospacedDigit()
                .foregroundStyle(Palette.mint)
        }
        .padding(14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle), saved \(usd(amount))")
    }

    private func budgetBreaksRow(_ count: Int64) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.dim)
                .frame(width: 30, height: 30)
                .background(Palette.faint.opacity(0.15), in: Circle())
                .overlay(Circle().stroke(Palette.line))
            Text("\(count) runaway run\(count == 1 ? "" : "s") stopped")
                .font(.mono).foregroundStyle(Palette.dim)
            Spacer()
        }
        .padding(14)
        .background(Palette.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) runaway runs stopped")
    }

    // MARK: - States

    private var loadingState: some View {
        ProgressView().tint(Palette.iris).frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func upgradeCard(_ info: PlanRequiredError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text("SAVINGS IS A PAID FEATURE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.faint)
            Text("Upgrade \(info.org) to see avoided spend from budget protection, semantic cache and model routing.")
                .font(.mono).foregroundStyle(Palette.dim)
            Button {
                // Deep-link handled by the system browser; upgradeUrl is server-provided.
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
        .accessibilityLabel("Savings requires a plan upgrade for \(info.org)")
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

    private func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
}

/// Loads `/v1/savings`, surfacing `plan_required` as a distinct phase so the
/// view can render an upgrade CTA rather than an error card.
@MainActor
@Observable
final class SavingsStore {
    enum Phase {
        case idle, loading
        case loaded(SavingsSummary)
        case planRequired(PlanRequiredError)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    func load(using client: APIClient) async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let summary = try await client.savings()
            phase = .loaded(summary)
        } catch APIClient.ClientError.planRequired(let info) {
            phase = .planRequired(info)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
