import SwiftUI
import WidgetKit

/// Claude Code usage at-a-glance — today's tokens with weekly-trend chip.
/// For a user who lives in Claude Code, this is the most-checked number.
struct ClaudeUsageWidget: Widget {
    let kind: String = "dk.pavi.ultron.claude-usage"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeUsageProvider()) { entry in
            ClaudeUsageView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude-forbrug")
        .description("Dagens tokens + uge-trend fra Claude Code.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ClaudeUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ClaudeUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeUsageEntry) -> Void) {
        completion(ClaudeUsageEntry(date: Date(), snapshot: WidgetSnapshotReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void) {
        // Main app refreshes Claude stats every 15s while Cockpit is open;
        // widget refresh at 5 min is fine — the trend chip doesn't whip
        // around second-by-second.
        let entry = ClaudeUsageEntry(date: Date(), snapshot: WidgetSnapshotReader.read())
        let next = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct ClaudeUsageView: View {
    let entry: ClaudeUsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Claude", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let c = entry.snapshot.claude {
                Text(formatTokens(c.todayTokens))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                Text("tokens i dag")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                trendChip(weeklyPct: c.weeklyTrendPct)
                if family == .systemMedium, let project = c.topProject {
                    Divider()
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.caption2)
                        Text(project)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.title.bold())
                Text("Ingen Claude-data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func trendChip(weeklyPct: Double) -> some View {
        let rounded = Int(weeklyPct.rounded())
        let color: Color = rounded > 10 ? .orange : (rounded < -10 ? .green : .secondary)
        let arrow = rounded > 0 ? "arrow.up" : (rounded < 0 ? "arrow.down" : "equal")
        return HStack(spacing: 4) {
            Image(systemName: arrow)
            Text("\(rounded)% ugen")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(color)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1f mia", Double(n) / 1_000_000_000) }
        if n >= 1_000_000     { return String(format: "%.0fM", Double(n) / 1_000_000) }
        if n >= 1_000         { return String(format: "%.0fK", Double(n) / 1_000) }
        return String(n)
    }
}
