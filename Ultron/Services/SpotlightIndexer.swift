import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// v1.4 Fase 3 slice: mirrors saved conversations into macOS Spotlight
/// (`CSSearchableIndex.default()`) so the user can find past chats from
/// ⌘Space instead of opening Ultron and scrolling the sidebar.
///
/// Each conversation becomes a `CSSearchableItem` with:
///   - `uniqueIdentifier`: the conversation UUID (lets us deep-link back).
///   - `domainIdentifier`: "ultron.conversations" so one tap in Settings →
///     Spotlight can hide or scope just Ultron's index.
///   - `title`: `displayTitle` (first user message preview).
///   - `contentDescription`: concatenated first + last ~400 chars of text so
///     Spotlight's content-match hit-rate is decent without ballooning the
///     index.
///   - `keywords`: mode-agnostic — just "Ultron", "chat", and any unique
///     first-message words. Keeps results scoped.
///
/// Clicking a Spotlight hit fires a `ultron://conversation?id=UUID` URL (the
/// app already handles that scheme in `AppDelegate.application(_:open:)` —
/// adding the conversation-id path is a 10-line follow-up). For now the
/// indexing alone gets the entries into Spotlight.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    private let domain = "ultron.conversations"
    private let index = CSSearchableIndex.default()

    private init() {}

    /// Index one conversation. Safe to call repeatedly — CoreSpotlight
    /// replaces items with the same `uniqueIdentifier`.
    func index(_ conversation: Conversation) {
        let item = CSSearchableItem(
            uniqueIdentifier: conversation.id.uuidString,
            domainIdentifier: domain,
            attributeSet: attributeSet(for: conversation)
        )
        index.indexSearchableItems([item]) { error in
            if let error {
                LoggingService.shared.log("Spotlight index failed for \(conversation.id): \(error)", level: .warning)
            }
        }
    }

    /// Remove a conversation from the index (called when the user deletes it
    /// from the sidebar). No-op if the index entry was never created.
    func remove(id: UUID) {
        index.deleteSearchableItems(withIdentifiers: [id.uuidString]) { error in
            if let error {
                LoggingService.shared.log("Spotlight delete failed for \(id): \(error)", level: .warning)
            }
        }
    }

    /// Nuclear reset — clears every conversation Ultron has ever indexed.
    /// Not wired to any UI yet; exposed for manual debugging.
    func clearAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
            if let error {
                LoggingService.shared.log("Spotlight clearAll failed: \(error)", level: .warning)
            }
        }
    }

    // MARK: - Attribute set

    private func attributeSet(for conversation: Conversation) -> CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.plainText)
        attrs.title = conversation.displayTitle
        attrs.contentDescription = Self.shortPreview(of: conversation)
        attrs.keywords = Self.keywords(for: conversation)
        attrs.contentModificationDate = conversation.updatedAt
        // contentURL lets Spotlight render a "visit" affordance; the actual
        // deep-link routing goes through NSUserActivity / CSSearchableItem
        // handler in AppDelegate.application(_:continue:) — but setting this
        // makes Quick Look previews point at our app instead of a plaintext
        // dead-end.
        attrs.contentURL = URL(string: "ultron://conversation?id=\(conversation.id.uuidString)")
        return attrs
    }

    /// First ~200 chars of the first user message + last ~200 chars of the
    /// final assistant reply. Gives Spotlight's substring matcher a decent
    /// surface to hit on without storing the entire transcript.
    private static func shortPreview(of conversation: Conversation) -> String {
        let firstUser = conversation.messages.first(where: { $0.role == .user })?.text ?? ""
        let lastAssistant = conversation.messages.last(where: { $0.role == .assistant })?.text ?? ""
        let head = String(firstUser.prefix(200))
        let tail = String(lastAssistant.prefix(200))
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " … " + tail
    }

    private static func keywords(for conversation: Conversation) -> [String] {
        var words: Set<String> = ["Ultron", "chat", "samtale"]
        if let firstUser = conversation.messages.first(where: { $0.role == .user })?.text {
            let tokens = firstUser
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .prefix(12)
                .map(String.init)
                .filter { $0.count >= 3 }
            tokens.forEach { words.insert($0) }
        }
        return Array(words)
    }
}
