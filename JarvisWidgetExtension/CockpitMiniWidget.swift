import SwiftUI
import WidgetKit

/// "Cockpit mini" — at-a-glance weather + commute + Claude usage so the
/// user can spot the important Cockpit signals without opening the app.
/// Medium size only (small is too cramped for 3 data points).
struct CockpitMiniWidget: Widget {
    let kind: String = "dk.pavi.jarvis.cockpit-mini"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CockpitMiniProvider()) { entry in
            CockpitMiniView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cockpit mini")
        .description("Vejret, din pendling og Claude-forbrug i dag.")
        .supportedFamilies([.systemMedium])
    }
}

struct CockpitMiniEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct CockpitMiniProvider: TimelineProvider {
    func placeholder(in context: Context) -> CockpitMiniEntry {
        CockpitMiniEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CockpitMiniEntry) -> Void) {
        completion(CockpitMiniEntry(date: Date(), snapshot: WidgetSnapshotReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CockpitMiniEntry>) -> Void) {
        // 2 min refresh matches the main app's Cockpit refresh cadence —
        // the file is always as fresh as the main app has made it.
        let entry = CockpitMiniEntry(date: Date(), snapshot: WidgetSnapshotReader.read())
        let next = Date().addingTimeInterval(2 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct CockpitMiniView: View {
    let entry: CockpitMiniEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            weatherBlock
            Divider()
            commuteBlock
            Divider()
            claudeBlock
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var weatherBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Vejr", systemImage: "cloud.sun.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let w = entry.snapshot.weather {
                HStack(spacing: 6) {
                    Image(systemName: w.conditionSymbol)
                        .font(.title2)
                    Text("\(Int(w.tempC.rounded()))°")
                        .font(.title.bold().monospacedDigit())
                }
                Text(w.locationLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("—").font(.title2.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var commuteBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Rute", systemImage: "car.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let c = entry.snapshot.commute {
                Text("\(c.durationMinutes) min")
                    .font(.title.bold().monospacedDigit())
                Text(c.destinationLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if c.trafficDelta != 0 {
                    Text(c.trafficDelta > 0 ? "+\(c.trafficDelta) min trafik" : "\(c.trafficDelta) min hurtigere")
                        .font(.caption2)
                        .foregroundStyle(c.trafficDelta > 0 ? .orange : .green)
                }
            } else {
                Text("—").font(.title2.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var claudeBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Claude", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let c = entry.snapshot.claude {
                Text(formatTokens(c.todayTokens))
                    .font(.title.bold().monospacedDigit())
                Text("i dag")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let project = c.topProject {
                    Text(project)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("—").font(.title2.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1f mia", Double(n) / 1_000_000_000) }
        if n >= 1_000_000     { return String(format: "%.0fM", Double(n) / 1_000_000) }
        if n >= 1_000         { return String(format: "%.0fK", Double(n) / 1_000) }
        return String(n)
    }
}
