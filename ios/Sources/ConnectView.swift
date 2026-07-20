import SwiftUI
import UIKit

/// The relay pairing flow's entry screen (docs/PHASE5.md W3: "Connect screen
/// + QR scanner"; itrat-console/13 D12.2 step 4): scan the QR the desktop's
/// Pocket panel renders, or, since the Simulator has no camera, paste the
/// same `genaryx-pocket://` link by hand (a DEBUG-only dev fallback).
/// `-autoPairURL`/`-autoPairCode` keep working unchanged here too: that is a
/// separate, direct-to-Cloud dev-harness path (no relay, no TLS pin), per
/// D12.2's own note that the dev harness "remains untouched for free/local
/// use".
struct ConnectView: View {
    var onPaired: (Account) -> Void

    @State private var showScanner = false
    @State private var showManualPair = false
    @State private var pastedLink = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    BrandMark(size: 96)
                        .padding(.top, 40)
                        .padding(.bottom, 48)
                    VStack(alignment: .leading, spacing: 20) {
                        brand
                        scanButton
                        if let error {
                            Text(error).font(.mono).foregroundStyle(Palette.ember)
                        }
                        if busy {
                            HStack(spacing: 8) {
                                ProgressView().tint(Palette.iris)
                                Text("Pairing…").font(.mono).foregroundStyle(Palette.dim)
                            }
                        }
                        #if DEBUG
                        devFallback
                        #endif
                        seal
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(22)
            }
        }
        .foregroundStyle(Palette.fg)
        .fullScreenCover(isPresented: $showScanner) {
            ScannerSheet(onScan: handleScannedPayload, onCancel: { showScanner = false })
        }
        .sheet(isPresented: $showManualPair) {
            PairView { account in
                showManualPair = false
                onPaired(account)
            }
        }
        .task {
            // Screenshot / UI-check hooks, DEBUG builds only. Both accept an
            // attacker-chosen address, so neither belongs in a shipped binary;
            // the paste-link field below is already `#if DEBUG` and these now
            // match it.
            #if DEBUG
            guard !busy else { return }
            // The RELAY path: the whole `genaryx-pocket://` link, exactly what
            // the QR carries. The simulator has no camera, and driving the
            // paste field through the UI is too flaky to build a capture
            // session on. Goes through `pair(withRawPayload:)`, so it exercises
            // the real parse, the real pin check and the real handoff of the
            // watch's code, not a shortcut around them.
            if let link = LaunchArgs.value("-autoRelayLink") {
                await pair(withRawPayload: link)
                return
            }
            // The older direct-to-Cloud dev-harness path (D12.2's own note:
            // "The dev harness... remains untouched for free/local use").
            guard let u = LaunchArgs.value("-autoPairURL"), let c = LaunchArgs.value("-autoPairCode") else { return }
            await autoPair(url: u, code: c)
            #endif
        }
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TokenFuse Pocket").font(.instrument(28))
            Text("Scan the QR on your Genaryx desktop to connect this iPhone.")
                .font(.system(size: 15)).foregroundStyle(Palette.dim)
        }
    }

    private var scanButton: some View {
        Button(action: presentScanner) {
            HStack {
                Image(systemName: "qrcode.viewfinder")
                Text("Scan QR").font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Palette.iris, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .accessibilityHint("Opens the camera to scan the pairing code shown on your desktop")
    }

    private func presentScanner() {
        error = nil
        if QRScannerView.isCameraScanningAvailable {
            showScanner = true
        } else {
            error = "Camera scanning isn't available here. On the Simulator, use the paste-link field below instead."
        }
    }

    #if DEBUG
    private var devFallback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Palette.line)
            Text("DEV: PASTE PAIRING LINK")
                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                .foregroundStyle(Palette.faint)
            TextField("genaryx-pocket://pair/v1?…", text: $pastedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
                .padding(12)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
            Button("Pair from pasted link") {
                Task { await pair(withRawPayload: pastedLink) }
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.iris)
            .disabled(busy || pastedLink.isEmpty)

            Button("Pair manually to a local plane instead") { showManualPair = true }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.dim)
                .padding(.top, 6)
        }
    }
    #endif

    private var seal: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 20)).foregroundStyle(Palette.mint)
            Text("A signing key is generated on this iPhone. The relay's certificate is pinned from the QR itself: a mismatch aborts pairing.")
                .font(.mono).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.mint.opacity(0.22)))
    }

    private func handleScannedPayload(_ payload: String) {
        showScanner = false
        Task { await pair(withRawPayload: payload) }
    }

    private func pair(withRawPayload raw: String) async {
        guard let intent = PairingIntent.parse(raw) else {
            error = "That code isn't a TokenFuse Pocket pairing link."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let (session, key) = try await RelayPairingService.pair(intent: intent, deviceName: UIDevice.current.name)
            SessionStore.save(session, key: key)
            // One scan admits both surfaces: hand the watch the second code
            // from the same QR (D12 W4). Deliberately after the phone's own
            // pairing succeeded, so a failed scan never spends the watch's
            // code, and deliberately fire-and-forget, since an operator with
            // no Apple Watch has still paired perfectly well.
            if let watchIntent = intent.watchIntent {
                let queued = WatchLink.shared.sendPairing(
                    watchIntent, expiresUnix: intent.expiresUnix)
                if !queued {
                    // Not an error: the phone is paired and fully usable. It
                    // means there is no watch to hand the second code to, or
                    // the link is not up yet. Surfacing this in the UI needs a
                    // post-pair notice screen, which does not exist yet; until
                    // it does, do not pretend the wrist is coming.
                    print("WatchLink: no watch to hand the pairing code to; wrist stays unpaired")
                }
            }
            onPaired(Account(session: session, key: key))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func autoPair(url: String, code: String) async {
        busy = true
        defer { busy = false }
        do {
            let (session, key) = try await PairingService.pair(planeURL: url, code: code, deviceName: UIDevice.current.name)
            SessionStore.save(session, key: key)
            onPaired(Account(session: session, key: key))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Full-screen camera scanner chrome (Cancel button + title) around
/// `QRScannerView`.
private struct ScannerSheet: View {
    var onScan: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            QRScannerView(onScan: onScan)
                .ignoresSafeArea()
                .navigationTitle("Scan pairing QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Palette.ink, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
    }
}
