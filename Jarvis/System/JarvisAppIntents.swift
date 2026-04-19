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

/// v1.2.2: 6-second fixed voice window, transcript copied to the system
/// pasteboard. Bypasses the paste/Notes dual-persist of the hotkey-driven
/// dictation path so Shortcut/Siri callers only get the clipboard side-effect.
@available(macOS 13.0, *)
struct DictateToClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate to Clipboard"
    static let description = IntentDescription("Diktér i 6 sekunder og kopiér teksten til udklipsholderen.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Make sure the HUD banner is visible while recording — users need a
        // visual cue that the mic is hot even when Siri/Shortcut triggered this.
        try await openJarvis(action: "dictate-clipboard", prompt: "")
        guard let delegate = NSApp.delegate as? AppDelegate else {
            return .result(value: "")
        }
        let transcript = await delegate.dictateToClipboard(seconds: 6)
        return .result(value: transcript)
    }
}

/// v1.2.2: fetch a URL, strip HTML, 3-bullet summary via Gemini summarize mode.
/// Returns the summary as a plain string so Shortcuts can pipe it into
/// e.g. a Notes block or a Reminder.
@available(macOS 13.0, *)
struct SummarizeURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize URL"
    static let description = IntentDescription("Hent en URL, opsummer i 3 bullet points.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "URL", description: "Webadressen der skal opsummeres.")
    var url: URL

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            return .result(value: "")
        }
        let summary = try await delegate.summarizeURL(url)
        return .result(value: "\(summary)\n\nKilde: \(url.absoluteString)")
    }
}

/// v1.2.2: compose `Context + Question` prompt → Gemini chat mode → reply text.
/// Synchronous one-shot — doesn't route through ChatPipeline because Shortcuts
/// needs a single completed string, not a streaming render.
@available(macOS 13.0, *)
struct AskWithContextIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Jarvis with context"
    static let description = IntentDescription("Stil et spørgsmål om medfølgende tekst.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Context", description: "Teksten Jarvis skal arbejde med.")
    var selectedText: String

    @Parameter(title: "Question", description: "Dit spørgsmål om teksten.")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            return .result(value: "")
        }
        let reply = try await delegate.askWithContext(
            selectedText: selectedText,
            question: question
        )
        return .result(value: reply)
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
        AppShortcut(
            intent: DictateToClipboardIntent(),
            phrases: [
                "Dictate to clipboard with \(.applicationName)",
                "Diktér til udklipsholder med \(.applicationName)"
            ],
            shortTitle: "Dictate → Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: SummarizeURLIntent(),
            phrases: [
                "Summarize URL with \(.applicationName)",
                "Opsummer URL med \(.applicationName)"
            ],
            shortTitle: "Summarize URL",
            systemImageName: "link.badge.plus"
        )
        AppShortcut(
            intent: AskWithContextIntent(),
            phrases: [
                "Ask \(.applicationName) with context",
                "Spørg \(.applicationName) med kontekst"
            ],
            shortTitle: "Ask with context",
            systemImageName: "text.bubble"
        )
    }
}
