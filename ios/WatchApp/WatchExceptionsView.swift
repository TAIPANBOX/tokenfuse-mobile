import SwiftUI
import WidgetKit

/// The wrist glance: the relay's own bounded exception queue, hottest first,
/// and nothing else. There is no full-fleet browse on this screen or on the
/// server route behind it (`GET /relay/v1/exceptions`, mirrors the phone's
/// own `ExceptionQueueView`) - the product rule this exists to serve is that
/// the wrist shows only the agents at or over their limit, never the whole
/// fleet. A kill from here is a deliberate, two-act ceremony
/// (`WatchRunKillView`), not a single tap.
struct WatchExceptionsView: View {
    let account: Account
    /// Fired when the relay rejects this watch's credential, so the root view
    /// can drop the dead session and offer a way back. Without this the watch
    /// had no path out of a server-side disconnect short of deleting and
    /// reinstalling the app, which is not something a customer can do to an
    /// Apple Watch without losing everything on it. Safe to call more than
    /// once: the handler is idempotent.
    var onRevoked: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WatchExceptionsStore()
    @State private var path: [ExceptionItem] = []

    /// Same cadence as the phone's `ExceptionQueueView` (docs/PHASE5.md:
    /// "POLL on a short interval + on foreground, no APNs in sim") - the
    /// relay's own engine updates internally on its own tick, this is only
    /// how often the watch asks it for the current snapshot.
    private static let pollInterval: Duration = .seconds(5)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    header
                    if let capacityFraction {
                        Fuse(fraction: capacityFraction, height: 7)
                    }
                    content
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 6)
            }
            .navigationDestination(for: ExceptionItem.self) { item in
                WatchRunKillView(item: item, account: account, onKilled: reload)
            }
            .containerBackground(Palette.ink.gradient, for: .navigation)
            .task {
                await reload()
                // Screenshot / UI-check hook: open a run's kill ceremony from a
                // launch arg, exactly as WatchFleetView did for RunDisplay.
                if path.isEmpty, let id = LaunchArgs.value("-openRun"),
                   let item = store.queue.first(where: { $0.runId == id }) {
                    path = [item]
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pollInterval)
                    if Task.isCancelled { break }
                    await reload()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reload() } }
            }
            .refreshable { await reload() }
        }
        .tint(Palette.mint)
    }

    private func reload() async {
        await store.load(using: account.reads)
        if store.deauthorized {
            // Mark the FACE as disconnected too. Writing `rate: 0, overCap:
            // false` here would have been the calmest possible lie on the
            // surface an operator glances at most: a revoked watch would sit
            // on the wrist reporting nothing burning and nothing over cap.
            FaceStore.saveDisconnected()
            WidgetCenter.shared.reloadAllTimelines()
            onRevoked()
            return
        }
        // Feed the watch-face complication exactly as WatchFleetView.reload
        // did: the fleet's burn rate, server-computed, plus whether anything
        // still live on the queue is hard (over_cap / runaway).
        let overCap = store.queue.contains { !$0.killed && $0.class.isHard }
        FaceStore.save(rate: store.aggregates?.burnRatePerMin ?? 0, overCap: overCap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Spend as a fraction of the fleet's own ceiling (spend + headroom, the
    /// two totals the relay's aggregates actually carry). `nil` before the
    /// first load, or if both are ever zero together - the fuse simply does
    /// not render rather than divide by zero.
    private var capacityFraction: Double? {
        guard let aggregates = store.aggregates else { return nil }
        let total = aggregates.spend + aggregates.headroom
        guard total > 0 else { return nil }
        return aggregates.spend / total
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text("FLEET BURN")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(Palette.faint)
                // Say it on the same line as the label, not buried below the
                // number: whoever raises their wrist reads the big figure
                // first, and they must not read it as current when it is not.
                //
                // Driven by a periodic clock rather than by the store's own
                // mutations. In the exact case this marker exists for - the
                // relay unreachable, the snapshot frozen - each poll sits in
                // URLSession's timeout, so waiting for the next state change to
                // trigger a render would leave the marker up to a minute late,
                // which is most of the window in which the stale number does
                // its damage.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let seconds = store.stalenessSeconds(now: context.date) {
                        Text("STALE \(Int(seconds))s")
                            .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(Palette.ember)
                            .accessibilityLabel(
                                "These figures are \(Int(seconds)) seconds old and are not updating")
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.2f", store.aggregates?.burnRatePerMin ?? 0))
                    .font(.system(size: 30, weight: .heavy)).monospacedDigit()
                Text("$/m").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.amber)
                Spacer()
                if let aggregates = store.aggregates {
                    Text(usd(aggregates.spend))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.deauthorized {
            // The root view is already tearing this screen down in response to
            // `onRevoked`; this only covers the frame or two in between, and it
            // must not be the old numbers.
            revokedState
        } else if case .failed(let message) = store.phase, store.aggregates == nil {
            errorState(message)
        } else if store.queue.isEmpty {
            switch store.phase {
            case .idle, .loading:
                ProgressView().tint(Palette.mint)
                    .frame(maxWidth: .infinity).padding(.top, 12)
            case .loaded:
                allClearState
            case .failed:
                EmptyView() // errorState above already covers this case
            }
        } else {
            ForEach(store.queue) { item in
                if let runId = item.runId, !item.killed {
                    NavigationLink(value: item) { WatchExceptionRow(item: item) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the kill ceremony for run \(runId)")
                } else {
                    WatchExceptionRow(item: item)
                }
            }
            digestSection
        }
    }

    /// What the guardrails already stopped, one line per (kind, agent).
    ///
    /// Deliberately terse and un-alarming: nothing here needs a decision, the
    /// breaker already fired. It earns its place on a 40mm screen because
    /// "reconciliation-batch, 171 stopped" is the one line that shows the
    /// governance working at scale, and listing those 171 individually would
    /// bury the handful of runs that DO still need the wrist.
    @ViewBuilder private var digestSection: some View {
        if !store.digest.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("ALREADY STOPPED")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Palette.faint)
                ForEach(store.digest) { row in
                    HStack(spacing: 5) {
                        Image(systemName: row.presentation.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.mint)
                        Text(row.agentShortName ?? row.presentation.label)
                            .font(.system(size: 11))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(row.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.mint)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(row.count) \(row.presentation.label.lowercased()) on \(row.agentShortName ?? "the fleet"), already stopped")
                }
                if store.queueTruncated > 0 {
                    Text("+\(store.queueTruncated) more need attention")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.ember)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 8)
        }
    }

    /// Calm, not alarming: an empty queue means the fleet is fine, so this
    /// says that plainly rather than showing nothing or hinting at failure.
    /// Matches the phone's own copy in `ExceptionQueueView.allClearState`.
    private var allClearState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Palette.mint)
            Text("All clear").font(.system(size: 15, weight: .semibold))
            Text("No exceptions. Every run is inside its budget.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.faint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .accessibilityElement(children: .combine)
    }

    /// Shown for the instant between the relay rejecting this watch and the
    /// root view swapping in the pairing prompt. Deliberately carries no
    /// figures at all: the point of the whole change is that a disconnected
    /// watch shows nothing rather than something plausible.
    private var revokedState: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.slash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.ember)
            Text("Disconnected").font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
    }

    /// Same tone as the phone's `errorCard`: a short title, the message, a
    /// way back in. Only shown when there is nothing already on screen to
    /// keep showing (`WatchExceptionsStore` keeps the last-known-good queue
    /// through a transient poll failure).
    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAN'T REACH THE RELAY")
                .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Palette.ember)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.dim)
            Button("Retry") { Task { await reload() } }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.iris)
        }
        .padding(.top, 6)
    }

    private func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
}

/// One exception on the wrist: class pill, run or incident id, and its fuse
/// when budget data is available. Mirrors the phone's `ExceptionRow`
/// hard-versus-soft colouring (`ExceptionClass.isHard`) so the two surfaces
/// read as one product, but shows nothing else - no headline, no Felyx
/// annotation. The wrist's whole point is the reduced surface.
struct WatchExceptionRow: View {
    let item: ExceptionItem

    private var accent: Color { item.killed ? Palette.faint : item.class.accent }
    private var hot: Bool { item.class.isHard && !item.killed }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                classPill
                // A run id when there is one, because that is the terse,
                // scannable thing. Otherwise the HEADLINE, not the incident id:
                // a fleet-wide detection has an id like `spend_spike:` with an
                // empty agent after the colon, which rendered as a dangling
                // "spend_spike:" on the wrist. The headline already says
                // "Spend spike on the fleet".
                Text(item.runId ?? item.headline)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    // Which end to cut depends on which string this is.
                    // A run id shares a long prefix with every other run in the
                    // fleet and differs only at the END
                    // (`...-eod-002-s063` versus `...-s128` versus `...-LIVE`),
                    // so cutting the tail rendered them all as the identical,
                    // useless "reconcil...". A headline is the opposite: it
                    // front-loads the meaning ("Spend spike on the fleet"), and
                    // cutting its head left "...on the fleet", which says
                    // nothing about what happened.
                    .truncationMode(item.runId != nil ? .head : .tail)
                    .foregroundStyle(item.killed ? Palette.dim : Palette.fg)
                Spacer()
                if item.killed {
                    Text("KILLED").font(.system(size: 8, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Palette.faint)
                }
            }
            if let fraction = item.fraction, item.budget != nil {
                Fuse(fraction: fraction, height: 6)
            }
        }
        .padding(8)
        .background(
            hot ? AnyShapeStyle(Palette.ember.opacity(0.08))
                : AnyShapeStyle(Palette.panel.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(hot ? Palette.ember.opacity(0.4) : Palette.line)
        )
        .opacity(item.killed ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var classPill: some View {
        Text(item.class.label.uppercased())
            .font(.system(size: 8, weight: .semibold)).tracking(0.4)
            .foregroundStyle(accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.35)))
    }

    private var accessibilityText: String {
        var parts = [item.class.label, item.runId ?? item.incidentId ?? item.key]
        if let fraction = item.fraction, item.budget != nil {
            parts.append("\(Int((fraction * 100).rounded())) percent of budget")
        }
        if item.killed { parts.append("killed") }
        return parts.joined(separator: ", ")
    }
}
