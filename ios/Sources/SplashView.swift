import SwiftUI

/// The first thing the app shows: the mark and the name, held for a beat.
///
/// It is not decoration covering a slow start. A cold launch into a paired
/// session lands on the exception queue while that queue is still empty, so the
/// operator's first frame used to be a blank list, which is the one thing this
/// screen must never say by accident: an empty queue means calm. Holding the
/// mark until the first read has had a moment means the queue is only ever
/// blank when it is genuinely empty.
///
/// Reduced-motion users get the same screen without the fade, and everybody
/// gets it for the same short beat: it is a breath, not a brand film.
struct SplashView: View {
    /// Long enough to read the name, short enough that nobody waits on it.
    static let hold: Duration = .milliseconds(900)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            VStack(spacing: 18) {
                BrandMark(size: 96)
                VStack(spacing: 6) {
                    Text("TokenFuse Pocket").font(.instrument(26))
                    Text("the kill switch on your wrist")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.dim)
                }
            }
            .opacity(shown || reduceMotion ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96)
        }
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.45)) { shown = true }
        }
    }
}
