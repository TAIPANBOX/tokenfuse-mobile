import SwiftUI

/// The Money tab: what the fleet is costing, from the relay's own bounded
/// roll-up (`GET /relay/v1/money`).
///
/// The queue answers "what needs a decision"; this answers "what is this
/// costing me", which is the question that made the pager worth opening when
/// nothing is on fire. It is a pull, never a push: nothing here interrupts.
struct MoneyView: View {
    let account: Account

    @State private var store = MoneyStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if case .failed(let message) = store.phase, !store.hasSnapshot {
                        FailureCard(message: message)
                    }
                    if let aggregates = store.aggregates {
                        totals(aggregates)
                    } else if store.phase == .loading {
                        ProgressView().tint(Palette.iris)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(18)
            }
            .background(Palette.ink.ignoresSafeArea())
            .navigationTitle("Money")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task { await load() }
        }
        .tint(Palette.iris)
    }

    private func totals(_ aggregates: ExceptionAggregates) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BURN RATE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.faint)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.2f", aggregates.burnRatePerMin))
                    .font(.instrument(40))
                Text("$/min").font(.system(size: 13)).foregroundStyle(Palette.amber)
            }
            HStack(spacing: 12) {
                figure("SPENT", usd(aggregates.spend))
                figure("HEADROOM", usd(aggregates.headroom))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line))
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold)).tracking(1.4)
                .foregroundStyle(Palette.faint)
            Text(value).font(.system(size: 17, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 12))
    }

    private func usd(_ value: Double) -> String { String(format: "$%.2f", value) }

    private func load() async {
        await store.load(using: account.reads)
    }
}

/// The same shape every relay-backed screen uses when it has nothing to show
/// and a reason why, rather than an empty screen that reads as "no spend".
struct FailureCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Can't reach the plane", systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text(message).font(.system(size: 12)).foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.amber.opacity(0.3)))
    }
}
