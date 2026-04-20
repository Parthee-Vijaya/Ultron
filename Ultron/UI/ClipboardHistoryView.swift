import AppKit
import SwiftUI

/// HUD panel listing recent clipboard entries. Same navy-glass visual language
/// as the Cockpit + Briefing panels so it slots into the existing shortcut
/// family without visual retraining.
struct ClipboardHistoryView: View {
    @Bindable var service: ClipboardHistoryService
    let onClose: () -> Void
    let onCopy: (ClipboardHistoryService.Entry) -> Void

    @State private var filter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider().opacity(0.2)
            list
        }
        .frame(width: 520, height: 460)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Label("Udklipsholder-historik", systemImage: "doc.on.clipboard")
                .font(.headline)
            Text("(\(service.entries.count) · max \(ClipboardHistoryService.capacity))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Pause", isOn: Binding(
                get: { service.isPaused },
                set: { service.isPaused = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Button {
                service.clearAll()
            } label: {
                Label("Ryd", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(service.entries.isEmpty)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Filter

    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Filtrér", text: $filter)
                .textFieldStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - List

    private var filtered: [ClipboardHistoryService.Entry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return service.entries }
        return service.entries.filter { $0.text.lowercased().contains(needle) }
    }

    @ViewBuilder
    private var list: some View {
        if service.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(service.isPaused ? "Optagelse er pauset." : "Intet kopieret endnu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            Text("Ingen match på \"\(filter)\".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        row(entry)
                        Divider().opacity(0.15)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ClipboardHistoryService.Entry) -> some View {
        Button {
            onCopy(entry)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.preview)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(Self.dateFormatter.string(from: entry.capturedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("· \(entry.text.count) tegn")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
