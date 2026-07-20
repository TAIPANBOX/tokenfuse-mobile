import SwiftUI

/// The kill ceremony on the wrist: the run's context (id, spend, its own fuse
/// when budget data exists), then two deliberate acts before anything is
/// signed and sent.
///
/// 1. **Arm.** The Digital Crown drives a 0...1 value; the control latches
///    armed once it first crosses ~90%. A crown turn is a real physical
///    gesture a stray tap cannot reproduce, which is the whole point of a
///    kill switch that is "not a single tap".
/// 2. **Confirm on wrist.** Tapping the armed control asks watchOS to confirm
///    the watch has not left the owner's wrist since it was last unlocked
///    (`Biometrics.confirmWristDetection`, `LAPolicy
///    .deviceOwnerAuthenticationWithWristDetection`). This is NOT Apple
///    Pay's double-click-side-button gesture - that is not available to
///    third-party watchOS apps. It is the platform's ordinary device-owner
///    check, with wrist continuity substituting for re-entering the
///    passcode.
///
/// Only once both acts succeed does this call `account.kill(run:)`, signed
/// **on this Apple Watch** by its own device key, enforced across every
/// gateway. Cancelling or failing the wrist check disarms quietly (no alarm,
/// no error text) and the whole ceremony restarts from the crown; a failed
/// kill request (a real error, unlike a cancelled wrist check) is shown and
/// also restarts the ceremony, so every kill attempt is a complete, fresh
/// act rather than a bare retry of the last one.
struct WatchRunKillView: View {
    let item: ExceptionItem
    let account: Account
    var onKilled: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var crownFocused: Bool

    /// 0...1 progress from the Digital Crown. Clamped, not wrap-around
    /// (`isContinuous: false` below), so overshooting the top just holds at 1.
    @State private var crownValue: Double = 0
    /// Latches true once `crownValue` first crosses `armThreshold`. A one-way
    /// latch rather than a live threshold check, so small crown jitter right
    /// at the top cannot un-arm the control out from under a user about to
    /// tap it.
    @State private var armed = false
    /// True only while the wrist-detection prompt is outstanding, distinct
    /// from `busy` (the network call) so the two waits can read differently.
    @State private var confirming = false
    @State private var busy = false
    @State private var killed = false
    /// Set only for a real failure after the wrist check already succeeded
    /// (the kill request itself). A cancelled or failed wrist check is
    /// deliberately silent, per the ceremony's own honesty rule.
    @State private var error: String?

    private static let armThreshold = 0.9

    private var hot: Bool { !item.killed && item.class.isHard }

    var body: some View {
        ScrollView {
            if killed {
                seal
            } else {
                VStack(spacing: 10) {
                    Text(item.runId ?? item.key)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                    Text("$\(String(format: "%.2f", item.spent))")
                        .font(.system(size: 34, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(hot ? Palette.ember : Palette.fg)
                    if let fraction = item.fraction, item.budget != nil {
                        Fuse(fraction: fraction, height: 7)
                    }

                    if item.killed {
                        Text("Already killed")
                            .font(.system(size: 12)).foregroundStyle(Palette.faint)
                    } else {
                        armControl

                        if let error {
                            Text(error).font(.system(size: 11)).foregroundStyle(Palette.ember)
                        }
                        Text("Signed on this Apple Watch")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.faint)
                    }
                }
                .padding(.top, 4)
            }
        }
        .containerBackground(Palette.ink.gradient, for: .navigation)
        .task {
            crownFocused = true
            // UI-check hook: drive the WHOLE ceremony (arm, confirm, kill)
            // rather than bypassing it, so a capture script can still land on
            // the armed state before the kill fires.
            if LaunchArgs.has("-autoKill"), !item.killed, !killed {
                await runAutoKillCeremony()
            }
        }
    }

    /// The crown-armed, tap-to-confirm control: a Fuse-styled progress track
    /// plus a label naming exactly what state it is in. Owns Digital Crown
    /// focus for as long as this screen is up.
    private var armControl: some View {
        VStack(spacing: 8) {
            Fuse(fraction: crownValue, height: 10)
            Text(armLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(armed ? Palette.ember : Palette.dim)
                .multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
        .onTapGesture { attemptKill() }
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation(
            $crownValue, from: 0, through: 1,
            sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
        )
        .onChange(of: crownValue) { _, newValue in
            if newValue >= Self.armThreshold { armed = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(armLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { attemptKill() }
    }

    /// The one wording per ceremony state, on a control that only ever shows
    /// one of these four at a time. "Armed. Tap to kill" rather than
    /// "Release to kill": there is no release gesture here, so the copy
    /// names the actual next action instead of borrowing one that does not
    /// apply.
    private var armLabel: String {
        if confirming { return "Confirming on wrist…" }
        if busy { return "Killing…" }
        return armed ? "Armed. Tap to kill" : "Turn the Crown to arm"
    }

    private var seal: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 42)).foregroundStyle(Palette.mint)
            Text("Killed").font(.system(size: 22, weight: .bold))
            Text(item.runId ?? item.key)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    /// The tap-when-armed path: acts 2 and 3 of the ceremony. A no-op unless
    /// actually armed and idle, so a stray tap on the unarmed control (or a
    /// second tap while one attempt is already in flight) does nothing.
    private func attemptKill() {
        guard armed, !confirming, !busy, let runId = item.runId else { return }
        confirming = true
        Task {
            let confirmed = await Biometrics.confirmWristDetection(reason: "Kill run \(runId)")
            confirming = false
            guard confirmed else {
                disarm() // cancelled or failed: quiet, no alarm, ceremony restarts
                return
            }
            await performKill(runId: runId)
        }
    }

    /// Drives the full three-step ceremony without any human input, for the
    /// screenshot/capture harness. Arms first and holds for a moment - so the
    /// armed state actually renders and is screenshot-able - before
    /// confirming and killing, rather than jumping straight to the result.
    private func runAutoKillCeremony() async {
        guard let runId = item.runId else { return }
        crownValue = 1
        armed = true
        try? await Task.sleep(for: .seconds(1))
        guard !killed else { return }
        confirming = true
        let confirmed = await Biometrics.confirmWristDetection(reason: "Kill run \(runId)")
        confirming = false
        guard confirmed else {
            disarm()
            return
        }
        await performKill(runId: runId)
    }

    private func performKill(runId: String) async {
        busy = true
        error = nil
        do {
            try await account.kill(run: runId)
            killed = true
            await onKilled()
            try? await Task.sleep(for: .seconds(1.3))
            dismiss()
        } catch APIClient.ClientError.http(401) {
            // This watch was disconnected server-side, mid-ceremony. Say that,
            // not "The plane returned HTTP 401.", and get out: the queue reload
            // behind this screen latches the same revocation and the root view
            // is already on its way to the pairing prompt. Parity with the
            // phone, which routes a 401 on kill into its own unpair handler
            // (`ExceptionQueueView`) rather than showing a status code.
            error = "This watch was disconnected. Pair it again from your iPhone."
            disarm()
            await onKilled()   // drives the reload that latches the revocation
            dismiss()
        } catch {
            self.error = error.localizedDescription
            disarm() // a real failure still restarts the ceremony from cold
        }
        busy = false
    }

    private func disarm() {
        armed = false
        crownValue = 0
    }
}
