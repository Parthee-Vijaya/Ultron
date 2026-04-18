import SwiftUI

/// Left-edge drawer showing past conversations (v1.1.5+). Groups by relative
/// time (I dag / I går / Denne uge / Ældre). Picking a row loads that
/// conversation into the active chat session; hover reveals a trash icon.
struct ConversationSidebar: View {
    let conversations: [ConversationStore.Metadata]
    let currentID: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onClose: () -> Void

    @State private var hoveringID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(JarvisTheme.hairline)

            if conversations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(Self.grouped(conversations), id: \.label) { group in
                            Section {
                                ForEach(group.items) { meta in
                                    row(meta)
                                }
                            } header: {
                                Text(group.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(JarvisTheme.textMuted)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(JarvisTheme.surfaceBase)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 240)
        .background(JarvisTheme.surfaceBase)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(JarvisTheme.accent)
            Text("Historik")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JarvisTheme.textPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(JarvisTheme.surfaceElevated)
                    )
            }
            .buttonStyle(.plain)
            .help("Skjul historik")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Row

    private func row(_ meta: ConversationStore.Metadata) -> some View {
        let isCurrent = meta.id == currentID
        let isHovering = hoveringID == meta.id

        return HStack(spacing: 6) {
            Button { onSelect(meta.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? JarvisTheme.textPrimary : JarvisTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(relativeDate(meta.updatedAt))
                        Text("·")
                        Text("\(meta.messageCount) beskeder")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(JarvisTheme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isCurrent ? JarvisTheme.accent.opacity(0.15) : (isHovering ? JarvisTheme.surfaceElevated : Color.clear))
                )
            }
            .buttonStyle(.plain)

            if isHovering {
                Button { onDelete(meta.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(JarvisTheme.textMuted)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(JarvisTheme.surfaceElevated)
                        )
                }
                .buttonStyle(.plain)
                .help("Slet samtale")
            }
        }
        .padding(.horizontal, 6)
        .onHover { hovering in
            hoveringID = hovering ? meta.id : (hoveringID == meta.id ? nil : hoveringID)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 18))
                .foregroundStyle(JarvisTheme.textMuted)
            Text("Ingen tidligere samtaler")
                .font(.system(size: 11))
                .foregroundStyle(JarvisTheme.textMuted)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Grouping

    private struct Group { let label: String; let items: [ConversationStore.Metadata] }

    private static func grouped(_ list: [ConversationStore.Metadata]) -> [Group] {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        var today: [ConversationStore.Metadata] = []
        var yesterday: [ConversationStore.Metadata] = []
        var thisWeek: [ConversationStore.Metadata] = []
        var older: [ConversationStore.Metadata] = []

        for item in list {
            if calendar.isDateInToday(item.updatedAt) {
                today.append(item)
            } else if calendar.isDateInYesterday(item.updatedAt) {
                yesterday.append(item)
            } else if calendar.dateComponents([.day], from: item.updatedAt, to: now).day ?? 99 < 7 {
                thisWeek.append(item)
            } else {
                older.append(item)
            }
        }

        var groups: [Group] = []
        if !today.isEmpty     { groups.append(Group(label: "I DAG", items: today)) }
        if !yesterday.isEmpty { groups.append(Group(label: "I GÅR", items: yesterday)) }
        if !thisWeek.isEmpty  { groups.append(Group(label: "DENNE UGE", items: thisWeek)) }
        if !older.isEmpty     { groups.append(Group(label: "ÆLDRE", items: older)) }
        return groups
    }

    private func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60       { return "\(Int(seconds))s" }
        if seconds < 3600     { return "\(Int(seconds / 60))m" }
        if seconds < 86_400   { return "\(Int(seconds / 3600))t" }
        let days = Int(seconds / 86_400)
        if days < 30          { return "\(days)d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d. MMM"
        formatter.locale = Locale(identifier: "da_DK")
        return formatter.string(from: date)
    }
}
