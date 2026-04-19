import AppKit
import SwiftUI

/// Left-edge drawer showing past conversations. v1.4 Fase 2c redesign mirrors
/// the Gemini macOS layout: search field at top, highlighted "Ny chat"
/// + "Mine ting" quick rows, "Chatsamtaler" section with the live list,
/// user avatar + full name anchored to the bottom. Hover a conversation to
/// reveal a trash icon (unchanged from v1.1.5).
struct ConversationSidebar: View {
    let conversations: [ConversationStore.Metadata]
    let currentID: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onClose: () -> Void
    /// v1.4: optional "Ny chat" handler — when present, the top quick row is
    /// wired to this. When nil (legacy callers) the row still renders but is
    /// disabled.
    var onNewChat: (() -> Void)? = nil

    @State private var hoveringID: UUID?
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerControls
            searchField
            quickRows
            sectionLabel("CHATSAMTALER")
            conversationList
            Spacer(minLength: 0)
            Divider().background(JarvisTheme.hairline)
            avatarFooter
        }
        .frame(width: 248)
        .background(JarvisTheme.surfaceBase.opacity(0.92))
    }

    // MARK: - Top controls (sidebar toggle)

    private var headerControls: some View {
        HStack(spacing: 8) {
            // Left side reserved for the system traffic lights on a window
            // that hosts its own titlebar; the chat panel is borderless so
            // we just pad.
            Spacer().frame(width: 70)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textSecondary)
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(JarvisTheme.surfaceElevated.opacity(0.8))
                    )
            }
            .buttonStyle(.plain)
            .help("Skjul sidebjælke")
            .accessibilityLabel("Skjul sidebjælke")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(JarvisTheme.textMuted)
            TextField("Søg", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(JarvisTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(JarvisTheme.surfaceElevated.opacity(0.65))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Quick rows (Ny chat, Mine ting)

    private var quickRows: some View {
        VStack(spacing: 2) {
            quickRow(
                title: "Ny chat",
                icon: "square.and.pencil",
                highlighted: true,
                action: { onNewChat?() }
            )
            .disabled(onNewChat == nil)
            quickRow(
                title: "Mine ting",
                icon: "star",
                highlighted: false,
                action: {}  // Placeholder: starred conversations feature lands in a follow-up.
            )
            .disabled(true)
            .opacity(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
    }

    private func quickRow(title: String, icon: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(highlighted ? JarvisTheme.textPrimary : JarvisTheme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: highlighted ? .semibold : .regular))
                    .foregroundStyle(highlighted ? JarvisTheme.textPrimary : JarvisTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(highlighted ? JarvisTheme.surfaceElevated.opacity(0.9) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section label

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(JarvisTheme.textMuted)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Conversation list

    @ViewBuilder
    private var conversationList: some View {
        if filteredConversations.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredConversations) { meta in
                        row(meta)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private var filteredConversations: [ConversationStore.Metadata] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return conversations }
        return conversations.filter { $0.title.lowercased().contains(query) }
    }

    // MARK: - Row

    private func row(_ meta: ConversationStore.Metadata) -> some View {
        let isCurrent = meta.id == currentID
        let isHovering = hoveringID == meta.id

        return HStack(spacing: 6) {
            Button { onSelect(meta.id) } label: {
                Text(meta.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? JarvisTheme.textPrimary : JarvisTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isCurrent ? JarvisTheme.surfaceElevated.opacity(0.9) :
                                  (isHovering ? JarvisTheme.surfaceElevated.opacity(0.4) : Color.clear))
                    )
            }
            .buttonStyle(.plain)

            if isHovering {
                Button { onDelete(meta.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(JarvisTheme.textMuted)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(JarvisTheme.surfaceElevated)
                        )
                }
                .buttonStyle(.plain)
                .help("Slet samtale")
                .accessibilityLabel("Slet samtale")
            }
        }
        .onHover { hovering in
            hoveringID = hovering ? meta.id : (hoveringID == meta.id ? nil : hoveringID)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 16))
                .foregroundStyle(JarvisTheme.textMuted)
            Text(searchText.isEmpty ? "Ingen tidligere samtaler" : "Ingen match")
                .font(.system(size: 11))
                .foregroundStyle(JarvisTheme.textMuted)
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Avatar footer

    private var avatarFooter: some View {
        HStack(spacing: 10) {
            avatar
            Text(Self.fullUserName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(JarvisTheme.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Circular avatar with the user's first initial on a dynamic tint —
    /// avoids hitting the user's photo library / NSUser asset, keeps the
    /// footer self-contained. Future: read `NSFullUserName`'s contacts
    /// photo if the user opts in.
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [JarvisTheme.accent, JarvisTheme.accentBright],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(Self.firstInitial)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
        }
        .frame(width: 26, height: 26)
    }

    private static var fullUserName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? NSUserName() : full
    }

    private static var firstInitial: String {
        guard let first = fullUserName.split(separator: " ").first,
              let ch = first.first else {
            return "?"
        }
        return String(ch).uppercased()
    }
}
