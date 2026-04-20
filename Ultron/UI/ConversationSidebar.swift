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

    /// v1.4 Fase 3: IDs of conversations surfaced by the semantic fallback
    /// (cosine-similarity against `SemanticIndex`) for the current `searchText`.
    /// When a row renders, we look up its id here to decide whether to show
    /// the small sparkle badge that signals "this match came from semantic
    /// search, not a title substring".
    ///
    /// Kept as a `Set` because the sidebar row lookup is hot — rendering
    /// budget for the sidebar is ~16ms per frame, and a hash-set lookup
    /// beats a linear scan every time the list re-renders during typing.
    @State private var semanticMatchIDs: Set<UUID> = []

    /// Preserves the cosine-ranked order of semantic matches so that the
    /// sidebar list shows them in descending similarity — the two substring
    /// sets and semantic sets are merged in `FilterResult.ordered(...)` but
    /// we need the ordering input to come from here.
    @State private var semanticOrdered: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerControls
            searchField
            quickRows
            sectionLabel("CHATSAMTALER")
            conversationList
            Spacer(minLength: 0)
            Divider().background(UltronTheme.hairline)
            avatarFooter
        }
        .frame(width: 248)
        .background(UltronTheme.surfaceBase.opacity(0.92))
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        // v1.4 Fase 3 semantic fallback: when typing, we defer to a 300ms
        // debounce, then run the actor-isolated embedding search off the
        // main thread. The `.task(id:)` modifier cancels in-flight work when
        // `searchText` changes again mid-debounce, so we don't spend
        // compute on keystrokes the user has already superseded.
        .task(id: searchText) { await refreshSemanticMatches() }
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
                    .foregroundStyle(UltronTheme.textSecondary)
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(UltronTheme.surfaceElevated.opacity(0.8))
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
                .foregroundStyle(UltronTheme.textMuted)
            TextField("Søg", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(UltronTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(UltronTheme.surfaceElevated.opacity(0.65))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Quick rows (Ny chat primary CTA, Mine ting)

    /// v1.4 Fase 2c polish: promote "Ny chat" to a proper primary action
    /// button — bigger, brand-accent-tinted, keyboard-shortcut-hinted. Sits
    /// directly under the search field so it's the first thing the eye
    /// catches when the sidebar opens.
    private var quickRows: some View {
        VStack(spacing: 6) {
            newChatButton
            mineTingRow
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
    }

    private var newChatButton: some View {
        Button {
            onNewChat?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("Ny chat")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("⌘N")
                    .font(.caption2.weight(.medium).monospaced())
                    .foregroundStyle(UltronTheme.textPrimary.opacity(0.6))
            }
            .foregroundStyle(UltronTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(UltronTheme.accent.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(UltronTheme.accent.opacity(0.45), lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .disabled(onNewChat == nil)
        .help("Ny samtale (⌘N)")
        .accessibilityLabel("Ny chat")
        .accessibilityHint("Starter en ny tom samtale")
    }

    private var mineTingRow: some View {
        Button(action: {}) {
            HStack(spacing: 10) {
                Image(systemName: "star")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UltronTheme.textMuted)
                    .frame(width: 18)
                Text("Mine ting")
                    .font(.caption)
                    .foregroundStyle(UltronTheme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .opacity(0.7)
        .accessibilityHidden(true)
    }

    // MARK: - Section label

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(UltronTheme.textMuted)
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

    /// Ordered list of conversations matching the current `searchText`.
    ///
    /// Two-tier search (v1.4 Fase 3):
    ///  1. Instant case-insensitive substring match on `meta.title` — cheap,
    ///     predictable, no async work involved. Drives the typing-latency
    ///     feel of the sidebar.
    ///  2. Semantic fallback, but only when the substring tier returned
    ///     fewer than 3 hits. The ids that should count as semantic matches
    ///     are pre-computed in `semanticMatchIDs` by `refreshSemanticMatches`
    ///     (triggered via `.task(id: searchText)` with a 300ms debounce).
    ///     We never block the render on the embedding work — this property
    ///     is purely synchronous.
    private var filteredConversations: [ConversationStore.Metadata] {
        Self.filter(
            conversations: conversations,
            query: searchText,
            semanticIDs: semanticMatchIDs,
            semanticOrder: semanticOrdered
        )
    }

    /// Threshold below which a semantic cosine score is considered too weak
    /// to surface in the sidebar. 0.35 was picked empirically — on the
    /// Danish sentence-embedding model, scores above 0.35 tend to reflect
    /// genuine topical overlap rather than noise.
    static let semanticScoreFloor: Double = 0.35

    /// Minimum number of substring hits required before we skip the
    /// semantic fallback entirely. If the user's query already matches
    /// several conversation titles, the semantic tier adds noise rather
    /// than signal.
    static let substringSatisfactionThreshold = 3

    /// Pure filter — no `@State`, no SwiftUI, no actor. Centralising the
    /// merge logic here gives us a testable unit that doesn't need
    /// `NLEmbedding` or the real `SemanticIndex`; tests supply the
    /// `semanticIDs` / `semanticOrder` directly.
    static func filter(
        conversations: [ConversationStore.Metadata],
        query rawQuery: String,
        semanticIDs: Set<UUID>,
        semanticOrder: [UUID]
    ) -> [ConversationStore.Metadata] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return conversations }

        // Tier 1: substring match on title. Preserves the caller-supplied
        // order (which is already newest-first from `loadAllMetadata`).
        let substringMatches = conversations.filter { $0.title.lowercased().contains(query) }
        if substringMatches.count >= substringSatisfactionThreshold {
            return substringMatches
        }

        // Tier 2: semantic fallback. Merge in ids from `semanticIDs` that
        // weren't already covered by the substring tier, ordered by the
        // cosine-rank `semanticOrder` so the most-similar matches lead.
        let substringIDs = Set(substringMatches.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        var tail: [ConversationStore.Metadata] = []
        tail.reserveCapacity(semanticIDs.count)
        for id in semanticOrder where semanticIDs.contains(id) && !substringIDs.contains(id) {
            // Silently drop ids that no longer exist in `conversations` —
            // e.g. the conversation was just deleted between the semantic
            // call firing and the view re-rendering. Filtering in
            // `byID[id]` keeps that invariant without tripping a crash.
            if let meta = byID[id] {
                tail.append(meta)
            }
        }

        return substringMatches + tail
    }

    /// Runs after each `searchText` change (300ms debounce, cancellable).
    /// Populates `semanticMatchIDs` / `semanticOrdered` based on the
    /// current substring results. Does nothing when the substring tier is
    /// already satisfied — the UI will never consult the semantic state
    /// in that case, so the embedding call would be pure waste.
    private func refreshSemanticMatches() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            if !semanticMatchIDs.isEmpty { semanticMatchIDs = [] }
            if !semanticOrdered.isEmpty { semanticOrdered = [] }
            return
        }

        // 300ms debounce. If the user keeps typing, this task is cancelled
        // by `.task(id:)` and `Task.sleep` throws `CancellationError` — we
        // catch via `try?` and silently abandon the stale run.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }

        // Skip the semantic call entirely when we already have enough
        // substring matches (fast path mirrors the filter logic).
        let lowercased = query.lowercased()
        let substringCount = conversations.reduce(0) { acc, meta in
            acc + (meta.title.lowercased().contains(lowercased) ? 1 : 0)
        }
        if substringCount >= Self.substringSatisfactionThreshold {
            if !semanticMatchIDs.isEmpty { semanticMatchIDs = [] }
            if !semanticOrdered.isEmpty { semanticOrdered = [] }
            return
        }

        let matches = await SemanticIndex.shared.search(query: query, topK: 8)
        if Task.isCancelled { return }

        let filtered = matches.filter { $0.score >= Self.semanticScoreFloor }
        semanticOrdered = filtered.map(\.id)
        semanticMatchIDs = Set(filtered.map(\.id))
    }

    // MARK: - Row

    private func row(_ meta: ConversationStore.Metadata) -> some View {
        let isCurrent = meta.id == currentID
        let isHovering = hoveringID == meta.id
        // v1.4 Fase 3: when a conversation only appears because of the
        // semantic fallback (no title substring match), mark it visually so
        // the user understands *why* it surfaced. Keeps the affordance
        // subtle — just a small sparkle glyph, not a noisy label.
        let isSemantic = semanticMatchIDs.contains(meta.id)

        return HStack(spacing: 6) {
            Button { onSelect(meta.id) } label: {
                HStack(spacing: 6) {
                    Text(meta.title)
                        .font(.footnote.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? UltronTheme.textPrimary : UltronTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isSemantic {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(UltronTheme.accent.opacity(0.85))
                            .help("Semantisk match — fundet via emnelighed, ikke titel")
                            .accessibilityLabel("semantisk match")
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isCurrent ? UltronTheme.surfaceElevated.opacity(0.9) :
                              (isHovering ? UltronTheme.surfaceElevated.opacity(0.4) : Color.clear))
                )
            }
            .buttonStyle(.plain)

            if isHovering {
                Button { onDelete(meta.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(UltronTheme.textMuted)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(UltronTheme.surfaceElevated)
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
                .foregroundStyle(UltronTheme.textMuted)
            Text(searchText.isEmpty ? "Ingen tidligere samtaler" : "Ingen match")
                .font(.caption2)
                .foregroundStyle(UltronTheme.textMuted)
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Avatar footer

    /// Shows the user's nickname (default "P") next to a circular avatar.
    /// Kept short so the sidebar width stays tight — full name was too noisy
    /// in the Gemini reference layout and clashed with the short-nickname
    /// greeting ("Hej P") up top.
    private var avatarFooter: some View {
        HStack(spacing: 10) {
            avatar
            Text(Self.displayNickname)
                .font(Font.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(UltronTheme.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Circular avatar with the user's first initial on a muted tint. v1.4
    /// Fase 2c swapped the earlier amber-gradient fill for a neutral
    /// surface-elevated background so the avatar doesn't compete visually
    /// with the brand-accent elements elsewhere.
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(UltronTheme.surfaceElevated)
                .overlay(Circle().stroke(UltronTheme.hairline, lineWidth: 0.5))
            Text(Self.displayNickname)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(UltronTheme.textPrimary)
        }
        .frame(width: 28, height: 28)
    }

    /// User-preferred short nickname shown both on the avatar and the
    /// footer label. Hardcoded to "P" per user preference (2026-04-19);
    /// future Settings surface lets other users set their own.
    private static let displayNickname: String = "P"
}
