import SwiftUI
import WidgetKit

/// The watch-face complication — the fleet's burn rate at a glance, no app to
/// open. Amber normally, ember when a run is over cap. Data comes from the app
/// over the app group (`FaceStore`); the app reloads the timeline on each refresh.
struct FaceEntry: TimelineEntry {
    let date: Date
    let rate: Double
    let overCap: Bool
    /// False once the relay has revoked this watch. The figures below are then
    /// the last ones it was entitled to read, and must not be presented as the
    /// fleet's current state on a surface glanced at without thought.
    var connected: Bool = true
}

struct FaceProvider: TimelineProvider {
    func placeholder(in context: Context) -> FaceEntry {
        FaceEntry(date: context.isPreview ? Date() : Date(timeIntervalSince1970: 0), rate: 1.90, overCap: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (FaceEntry) -> Void) {
        let snapshot = FaceStore.load()
        completion(FaceEntry(date: Date(), rate: snapshot.rate,
                             overCap: snapshot.overCap, connected: snapshot.connected))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FaceEntry>) -> Void) {
        let snapshot = FaceStore.load()
        let entry = FaceEntry(date: Date(), rate: snapshot.rate,
                              overCap: snapshot.overCap, connected: snapshot.connected)
        // The app reloads this on every refresh; the schedule is a fallback.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct FaceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FaceEntry

    private var tint: Color {
        guard entry.connected else { return Palette.faint }
        return entry.overCap ? Palette.ember : Palette.amber
    }
    /// A disconnected watch shows a dash, never a number. The figure it last
    /// read is not the fleet's current state and a glance cannot tell the
    /// difference, so there is nothing honest to put here.
    private var rate2: String {
        entry.connected ? String(format: "%.2f", entry.rate) : "--"
    }
    private var rate1: String {
        entry.connected ? String(format: "%.1f", entry.rate) : "--"
    }
    private var symbol: String { entry.connected ? "bolt.fill" : "bolt.slash.fill" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
                    Text(rate1).font(.system(size: 16, weight: .heavy)).monospacedDigit()
                        .minimumScaleFactor(0.6)
                }
            }
        case .accessoryCorner:
            Text(rate1).font(.system(size: 17, weight: .heavy)).monospacedDigit()
                .foregroundStyle(tint)
                .widgetLabel("\(rate2) $/m")
        case .accessoryInline:
            Label(entry.connected ? "\(rate2) $/m" : "disconnected", systemImage: symbol)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("FLEET BURN").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(rate2).font(.system(size: 22, weight: .heavy)).monospacedDigit()
                        Text("$/m").font(.system(size: 11)).foregroundStyle(tint)
                    }
                }
                Spacer()
            }
        default:
            Text("\(rate2) $/m").font(.system(size: 14, weight: .bold))
        }
    }
}

struct TokenFuseBurnComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TokenFuseBurn", provider: FaceProvider()) { entry in
            FaceView(entry: entry)
        }
        .configurationDisplayName("Fleet burn")
        .description("Your agent fleet's $/min, on the watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

@main
struct TokenFuseWatchWidgets: WidgetBundle {
    var body: some Widget {
        TokenFuseBurnComplication()
    }
}
