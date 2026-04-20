import SwiftUI

/// Læringsspor (Phase 3e viewer) — renders the last N `TraceEntry` rows from
/// `~/Library/Logs/Ultron/trace.jsonl`. Each row lets the user rate the answer
/// (thumbs-up / thumbs-down) which writes back to the JSONL. Future phases
/// will feed ratings into routing policy + offline DSPy/GEPA optimisation.
struct SettingsTracesPane: View {
    @State private var entries: [TraceEntry] = []
    @State private var refreshToken = UUID()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        SettingsPane(
            title: "Læringsspor",
            subtitle: "Seneste LLM-kald pr. provider. Tommel op/ned ratings gemmes — bruges senere til auto-routing + offline optimering."
        ) {
            SettingsCard(
                title: "Oversigt",
                footer: "Kilde: ~/Library/Logs/Ultron/trace.jsonl (roteres ved 10 MB)."
            ) {
                summaryRow
            }

            SettingsCard(title: "Seneste kald") {
                if entries.isEmpty {
                    Text("Ingen trace-entries endnu. Send en besked via agent chat eller /digest for at fylde sporet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            entryRow(entry)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .id(refreshToken)
    }

    @ViewBuilder
    private var summaryRow: some View {
        let localCalls = entries.filter { $0.provider == "ollama" }.count
        let cloudCalls = entries.count - localCalls
        let totalJoules = entries.reduce(0.0) { $0 + $1.joulesEst }
        let avgLatency = entries.isEmpty ? 0 : entries.reduce(0) { $0 + $1.latencyMs } / entries.count
        HStack(spacing: 16) {
            stat(label: "Kald i alt", value: "\(entries.count)")
            Divider().frame(height: 28)
            stat(label: "Lokalt", value: "\(localCalls)")
            stat(label: "Cloud", value: "\(cloudCalls)")
            Divider().frame(height: 28)
            stat(label: "Joules (lokal)", value: String(format: "%.1f", totalJoules))
            stat(label: "Snit-latency", value: "\(avgLatency) ms")
            Spacer()
            Button("Genindlæs") { reload() }
                .controlSize(.small)
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: TraceEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    providerBadge(entry.provider)
                    Text(entry.model)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.reason.isEmpty {
                        Text("· \(entry.reason)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: entry.timestamp))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("· \(entry.taskType)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("· in \(entry.tokensIn) / out \(entry.tokensOut) tok")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("· \(entry.latencyMs) ms")
                        .font(.caption2).foregroundStyle(.secondary)
                    if entry.joulesEst > 0 {
                        Text("· \(String(format: "%.2f", entry.joulesEst)) J")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let err = entry.errorDescription {
                        Text("· ✗ \(err)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Button {
                TraceStore.shared.rate(id: entry.id, rating: entry.rating == 1 ? 0 : 1)
                // Optimistic local update; reload pulls fresh data for the
                // rest of the file.
                bumpRating(id: entry.id, to: entry.rating == 1 ? 0 : 1)
            } label: {
                Image(systemName: entry.rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(entry.rating == 1 ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            Button {
                TraceStore.shared.rate(id: entry.id, rating: entry.rating == -1 ? 0 : -1)
                bumpRating(id: entry.id, to: entry.rating == -1 ? 0 : -1)
            } label: {
                Image(systemName: entry.rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(entry.rating == -1 ? .red : .secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private func bumpRating(id: UUID, to rating: Int) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            let entry = entries[idx]
            entries[idx] = TraceEntry(
                id: entry.id,
                timestamp: entry.timestamp,
                provider: entry.provider,
                model: entry.model,
                taskType: entry.taskType,
                tokensIn: entry.tokensIn,
                tokensOut: entry.tokensOut,
                latencyMs: entry.latencyMs,
                joulesEst: entry.joulesEst,
                reason: entry.reason,
                rating: rating,
                errorDescription: entry.errorDescription
            )
        }
    }

    private func providerBadge(_ provider: String) -> some View {
        let (bg, fg) = badgeColors(for: provider)
        return Text(provider.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func badgeColors(for provider: String) -> (Color, Color) {
        switch provider {
        case "ollama":    return (.green.opacity(0.25), .green)
        case "anthropic": return (.orange.opacity(0.25), .orange)
        case "gemini":    return (.blue.opacity(0.25), .blue)
        case "auto":      return (.purple.opacity(0.25), .purple)
        default:          return (.gray.opacity(0.25), .secondary)
        }
    }

    private func reload() {
        entries = TraceStore.shared.recent(limit: 200)
        refreshToken = UUID()
    }
}
