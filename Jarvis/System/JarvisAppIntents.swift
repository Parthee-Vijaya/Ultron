import AppIntents
import AppKit
import Foundation

/// v1.1.8: macOS Shortcuts app integration via AppIntents. Lets users build
/// automations like "When a file is added to ~/Downloads, run 'Summarize in
/// Jarvis'".
///
/// Each intent routes to a `jarvis://` URL so the existing URL handler owns
/// the actual execution path — one code path, two entry points.

@available(macOS 13.0, *)
struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Jarvis"
    static let description = IntentDescription("Stil Jarvis et spørgsmål og få et kildebaseret svar.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt", description: "Det du vil spørge Jarvis om.")
    var prompt: String

    func perform() async throws -> some IntentResult {
        try await openJarvis(action: "qna", prompt: prompt)
        return .result()
    }
}

@available(macOS 13.0, *)
struct OpenJarvisChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Jarvis Chat"
    static let description = IntentDescription("Åbn Jarvis-chatvinduet og forudfyld evt. prompt-feltet.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt", description: "Valgfri start-prompt.", default: "")
    var prompt: String

    func perform() async throws -> some IntentResult {
        try await openJarvis(action: "chat", prompt: prompt)
        return .result()
    }
}

@available(macOS 13.0, *)
struct VisionInJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Jarvis about screen"
    static let description = IntentDescription("Tag et skærmbillede og stil Jarvis et spørgsmål om det.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt", description: "Hvad du vil vide om skærmen.")
    var prompt: String

    func perform() async throws -> some IntentResult {
        try await openJarvis(action: "vision", prompt: prompt)
        return .result()
    }
}

@available(macOS 13.0, *)
struct OpenCockpitIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Jarvis Cockpit"
    static let description = IntentDescription("Åbn Jarvis Cockpit-panelet (vejr, system, commute).")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await openJarvis(action: "cockpit", prompt: "")
        return .result()
    }
}

@available(macOS 13.0, *)
struct OpenBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Jarvis Briefing"
    static let description = IntentDescription("Åbn Jarvis Briefing-panelet (nyheder + historie).")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await openJarvis(action: "briefing", prompt: "")
        return .result()
    }
}

/// Builds and opens a `jarvis://` URL. AppIntents can't directly call into
/// the app's main-actor state because they might run when the app isn't
/// active; routing through the URL handler guarantees the app is launched
/// first (`openAppWhenRun`) and then the existing URL path takes over.
@available(macOS 13.0, *)
private func openJarvis(action: String, prompt: String) async throws {
    var components = URLComponents()
    components.scheme = "jarvis"
    components.host = action
    if !prompt.isEmpty {
        components.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
    }
    guard let url = components.url else { return }
    await MainActor.run {
        NSWorkspace.shared.open(url)
    }
}

/// Registers the AppIntents bundle so Shortcuts.app discovers the actions.
@available(macOS 13.0, *)
struct JarvisAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Spørg \(.applicationName)"
            ],
            shortTitle: "Ask Jarvis",
            systemImageName: "questionmark.circle"
        )
        AppShortcut(
            intent: OpenJarvisChatIntent(),
            phrases: [
                "Open \(.applicationName) chat",
                "Åbn \(.applicationName) chat"
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: VisionInJarvisIntent(),
            phrases: [
                "Ask \(.applicationName) about screen",
                "\(.applicationName) vision"
            ],
            shortTitle: "Vision",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: OpenCockpitIntent(),
            phrases: ["Open \(.applicationName) Cockpit"],
            shortTitle: "Cockpit",
            systemImageName: "gauge.open.with.lines.needle.33percent"
        )
        AppShortcut(
            intent: OpenBriefingIntent(),
            phrases: ["Open \(.applicationName) Briefing"],
            shortTitle: "Briefing",
            systemImageName: "newspaper"
        )
    }
}
