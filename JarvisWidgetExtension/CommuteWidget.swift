import SwiftUI
import WidgetKit

/// Small widget for the default Hjem/Rute commute — pure "how long til I'm
/// home" + traffic delta. Best size is small/square; medium shows the same
/// data plus arrival ETA.
struct CommuteWidget: Widget {
    let kind: String = "dk.pavi.jarvis.commute"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CommuteProvider()) { entry in
            CommuteView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Rute")
        .description("Rejsetid + trafik for din aktive rute.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CommuteEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct CommuteProvider: TimelineProvider {
    func placeholder(in context: Context) -> CommuteEntry {
        CommuteEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CommuteEntry) -> Void) {
        completion(CommuteEntry(date: Date(), snapshot: WidgetSnapshotReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CommuteEntry>) -> Void) {
        let entry = CommuteEntry(date: Date(), snapshot: WidgetSnapshotReader.read())
        let next = Date().addingTimeInterval(2 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct CommuteView: View {
    let entry: CommuteEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Rute", systemImage: "car.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let c = entry.snapshot.commute {
                Text("\(c.durationMinutes) min")
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                Text(c.destinationLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if c.trafficDelta != 0 {
                    HStack(spacing: 4) {
                        Image(systemName: c.trafficDelta > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption)
                        Text(c.trafficDelta > 0 ? "+\(c.trafficDelta) min" : "\(c.trafficDelta) min")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(c.trafficDelta > 0 ? .orange : .green)
                } else {
                    Text("fri bane")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if family == .systemMedium, let arrival = c.arrivalAt {
                    Text("Ankomst \(arrival.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.title.bold())
                Text("Åbn Cockpit for at beregne rute")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
