import Foundation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "", messages: [ChatMessage] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Derive title from the first user message
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let preview = firstUser.text.prefix(50)
            return preview.count < firstUser.text.count ? "\(preview)..." : String(preview)
        }
        return "Ny samtale"
    }
}

class ConversationStore {
    private let directory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = appSupport.appendingPathComponent("Jarvis/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Save

    func save(_ conversation: Conversation) {
        let url = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(conversation)
            try data.write(to: url, options: .atomic)
        } catch {
            LoggingService.shared.log("Failed to save conversation: \(error)", level: .error)
        }
    }

    /// Save current ChatSession as a conversation
    func saveSession(_ session: ChatSession, existingID: UUID? = nil) -> UUID {
        let id = existingID ?? UUID()
        var conversation = Conversation(id: id, messages: session.messages)
        conversation.updatedAt = Date()
        save(conversation)
        return id
    }

    // MARK: - Load

    func loadAll() -> [Conversation] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Conversation? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Conversation.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) -> Conversation? {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Conversation.self, from: data)
    }

    // MARK: - Delete

    func delete(id: UUID) {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Metadata (v1.1.5)

    /// Slim view of a conversation used by the sidebar — lets us render the
    /// full history list without deserialising every conversation's messages
    /// up-front. Loads on-demand when the user picks one.
    struct Metadata: Identifiable, Equatable {
        let id: UUID
        let title: String
        let updatedAt: Date
        let messageCount: Int
    }

    /// All conversations' metadata, newest-first. We still round-trip through
    /// `Conversation.displayTitle` for consistency, but the sidebar only
    /// renders title / timestamp / count — so this is strictly cheaper than
    /// `loadAll()` for users with many saved chats.
    func loadAllMetadata() -> [Metadata] {
        loadAll().map { convo in
            Metadata(
                id: convo.id,
                title: convo.displayTitle,
                updatedAt: convo.updatedAt,
                messageCount: convo.messages.count
            )
        }
    }
}
