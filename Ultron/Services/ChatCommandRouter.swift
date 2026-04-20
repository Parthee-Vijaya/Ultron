import AppKit
import Foundation

/// β.11 coordination layer for the unified chat command bar. Takes a
/// `(Mode, input)` pair from the UI and dispatches to the right pipeline or
/// service. All results feed back into the same `ChatSession`, so the chat's
/// message list renders everything uniformly regardless of which mode ran.
///
/// Direct hotkey invocations (⌥Q, ⌥⇧Space, etc.) do NOT route through this
/// router — they keep their legacy paste/HUD flow. This router is only used
/// when the user picks a mode inside the chat window.
@MainActor
final class ChatCommandRouter {
    enum RouterError: LocalizedError {
        case pickerCancelled
        case screenCaptureFailed(Error)
        case summaryFailed(Error)
        case geminiFailed(Error)

        var errorDescription: String? {
            switch self {
            case .pickerCancelled:          return "Ingen fil valgt."
            case .screenCaptureFailed(let e): return "Kunne ikke tage skærmbillede: \(e.localizedDescription)"
            case .summaryFailed(let e):     return "Opsummering fejlede: \(e.localizedDescription)"
            case .geminiFailed(let e):      return "AI-kald fejlede: \(e.localizedDescription)"
            }
        }
    }

    private let chatPipeline: ChatPipeline
    /// Factory keyed by provider type — Anthropic vs Ollama pipelines share
    /// the AgentChatPipeline class but get different AIProvider backings.
    private let agentChatPipeline: (AIProviderType) -> AgentChatPipeline?
    private let geminiClient: GeminiClient
    private let screenCapture: ScreenCaptureService
    private let summaryService: DocumentSummaryService
    private let chatSession: ChatSession
    /// v1.4 Fase 3 (first slice): intercepts trivial queries (time, date, IP,
    /// battery, WiFi, weather) and answers locally before the AI call.
    /// Optional so older callers (hotkey-only codepaths) can still construct
    /// the router without a full InfoModeService instance.
    private let instantAnswers: InstantAnswerProvider?
    /// Phase 4a: optional InfoModeService reference so `/digest` can pull the
    /// current Cockpit snapshot. Left optional so older hotkey-only code paths
    /// (which don't need digest) can still construct the router.
    private let infoModeService: InfoModeService?

    init(
        chatPipeline: ChatPipeline,
        agentChatPipeline: @escaping (AIProviderType) -> AgentChatPipeline?,
        geminiClient: GeminiClient,
        screenCapture: ScreenCaptureService,
        summaryService: DocumentSummaryService,
        chatSession: ChatSession,
        instantAnswers: InstantAnswerProvider? = nil,
        infoModeService: InfoModeService? = nil
    ) {
        self.chatPipeline = chatPipeline
        self.agentChatPipeline = agentChatPipeline
        self.geminiClient = geminiClient
        self.screenCapture = screenCapture
        self.summaryService = summaryService
        self.chatSession = chatSession
        self.instantAnswers = instantAnswers
        self.infoModeService = infoModeService
    }

    // MARK: - Public

    /// Run a mode-scoped command. `input` semantics vary with
    /// `mode.inputKind`:
    ///   - `.text`      → plain user prompt
    ///   - `.voice`     → ignored (mic capture starts elsewhere via RecordingPipeline)
    ///   - `.screenshot`→ user's optional question about the screen
    ///   - `.document`  → ignored (the file picker launches on trigger)
    func run(mode: Mode, input: String, image: Data? = nil) async {
        // v1.4 Fase 2b.4: if an image is attached, always route through the
        // Vision-style text+image path regardless of the mode's inputKind.
        // Users attach images in chat mode expecting "describe this" style
        // replies, not a hotkey-triggered Vision screenshot flow.
        if let image {
            await runTextWithImage(mode: mode, input: input, image: image)
            return
        }
        switch mode.inputKind {
        case .text:
            await runText(mode: mode, input: input)
        case .screenshot:
            await runVision(mode: mode, input: input)
        case .document:
            await runSummarize(mode: mode)
        case .voice:
            // Dictation from the chat bar is handled by the RecordingPipeline
            // directly — the command bar starts/stops the mic, no router step.
            break
        }
    }

    /// v1.4 Fase 2b.4: text + attached image via Gemini's text+image path.
    /// Uses the same ChatSession streaming pattern so the answer shows up
    /// in the normal message list and the user's bubble just carries the
    /// prompt. Image is passed in-memory; we never persist it on disk.
    private func runTextWithImage(mode: Mode, input: String, image: Data) async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Beskriv billedet."
            : input
        chatSession.addUserMessage(prompt)
        let placeholderID = chatSession.addAssistantMessage("")
        chatSession.isStreaming = true
        chatSession.currentStep = ProcessingStep(.thinking(provider: "Gemini"))
        defer {
            chatSession.isStreaming = false
            chatSession.currentStep = nil
        }

        let effectiveMode = mode.outputType == .chat ? mode : BuiltInModes.chat
        let result = await geminiClient.sendTextWithImage(
            prompt: prompt, mode: effectiveMode, imageData: image
        )
        switch result {
        case .success(let text):
            chatSession.updateAssistant(id: placeholderID, text: text)
        case .failure(let error):
            chatSession.markAssistantError(
                id: placeholderID,
                errorText: RouterError.geminiFailed(error).errorDescription ?? "AI-kald fejlede.",
                sourceModeID: effectiveMode.id,
                sourcePrompt: prompt
            )
        }
    }

    // MARK: - /digest (Phase 4a)

    /// Build a briefing prompt from the current Cockpit snapshot and send it
    /// through the active mode's pipeline. User sees the prompt expanded in
    /// the chat (so they can see what context the LLM got) followed by the
    /// LLM's reply streamed in.
    private func runDigest(mode: Mode, extraContext: String) async {
        guard let info = infoModeService else {
            chatSession.addUserMessage("/digest")
            _ = chatSession.addAssistantMessage("Digest-kommandoen er ikke wired op i denne build (InfoModeService mangler).")
            return
        }
        let snapshot = info.digestContext()
        var userFacing = "/digest"
        if !extraContext.isEmpty { userFacing += " " + extraContext }

        let extraNote = extraContext.isEmpty ? "" : "\n\nBrugerens ekstra kontekst: \(extraContext)"
        let prompt = """
        Lav en kort morgen-briefing på samme sprog som konteksten. Brug 3-5 bullet \
        points. Vær specifik med tal (tid, temperatur, forsinkelser). Nævn kun det \
        der faktisk står i konteksten — gæt ikke på mail, kalender eller andet der \
        ikke er listet.

        Kontekst fra Ultron Cockpit:

        \(snapshot)\(extraNote)
        """

        chatSession.addUserMessage(userFacing)

        if mode.provider != .gemini, mode.agentTools,
           let agent = agentChatPipeline(mode.provider) {
            agent.sendTextMessage(prompt)
        } else {
            chatPipeline.sendTextMessage(prompt, mode: mode)
        }
    }

    // MARK: - Text (Chat / Q&A / Translate / Agent / custom text modes)

    private func runText(mode: Mode, input: String) async {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Phase 4a: /digest command — expand into a briefing prompt using the
        // current Cockpit snapshot. Runs through the normal pipeline so it
        // respects the mode's provider (Claude, Ollama, Gemini), tools, etc.
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("/digest") {
            await runDigest(mode: mode, extraContext: String(trimmed.dropFirst("/digest".count)).trimmingCharacters(in: .whitespaces))
            return
        }

        // v1.4 Fase 3 preflight: for plain chat / Q&A / default text modes,
        // try the instant-answer provider before reaching for the network.
        // Agent + VibeCode + Professional etc. intentionally skip this — the
        // user wants *transformation*, not a lookup. Grounded Q&A benefits
        // most (trivial factual query → 0 Gemini round-trip).
        if let instantAnswers, mode.provider == .gemini, !mode.agentTools,
           mode.outputType == .chat || mode.outputType == .hud,
           let answer = await instantAnswers.match(query: input) {
            LoggingService.shared.log("InstantAnswer hit for: \(input.prefix(60))")
            chatSession.addUserMessage(input)
            _ = chatSession.addAssistantMessage(answer)
            await MetricsService.shared.record(
                phase: .modelCall, durationMs: 0, mode: mode.name, transport: "instant-answer"
            )
            return
        }

        // Providers that go through the agent pipeline (Anthropic + Ollama).
        // Gemini routes through ChatPipeline below.
        if mode.provider != .gemini, mode.agentTools,
           let agent = agentChatPipeline(mode.provider) {
            agent.sendTextMessage(input)
        } else {
            // Gemini path — reuses ChatPipeline but with the picked mode's
            // systemPrompt + webSearch flag.
            chatPipeline.sendTextMessage(input, mode: mode)
        }
    }

    // MARK: - Screenshot (Vision)

    private func runVision(mode: Mode, input: String) async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Beskriv hvad du ser på skærmen."
            : input

        chatSession.addUserMessage(prompt)
        let placeholderID = chatSession.addAssistantMessage("")
        chatSession.isStreaming = true
        defer { chatSession.isStreaming = false }

        let imageData: Data
        do {
            imageData = try await screenCapture.captureActiveWindow()
        } catch {
            chatSession.markAssistantError(
                id: placeholderID,
                errorText: RouterError.screenCaptureFailed(error).errorDescription ?? "Skærmfangst fejlede.",
                sourceModeID: mode.id,
                sourcePrompt: prompt
            )
            return
        }

        let result = await geminiClient.sendTextWithImage(
            prompt: prompt,
            mode: mode,
            imageData: imageData
        )
        switch result {
        case .success(let text):
            chatSession.updateAssistant(id: placeholderID, text: text)
        case .failure(let error):
            chatSession.markAssistantError(
                id: placeholderID,
                errorText: RouterError.geminiFailed(error).errorDescription ?? "AI-kald fejlede.",
                sourceModeID: mode.id,
                sourcePrompt: prompt
            )
        }
    }

    // MARK: - Drag-drop entry point

    /// v1.1.5: route a dropped file to the right mode based on UTI.
    /// Images → Vision (with optional pre-typed text as prompt).
    /// PDF / DOCX / TXT / MD → Summarize.
    /// Anything else: no-op (can't do anything useful).
    func runDropped(url: URL, prefilledText: String = "") async {
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"]
        let docExts: Set<String> = ["pdf", "docx", "txt", "md", "rtf"]

        if imageExts.contains(ext) {
            await runDroppedImage(url: url, prefilledText: prefilledText)
        } else if docExts.contains(ext) {
            await runDroppedDocument(url: url)
        } else {
            LoggingService.shared.log("Unsupported drop file type: .\(ext)", level: .info)
        }
    }

    private func runDroppedImage(url: URL, prefilledText: String) async {
        guard let imageData = try? Data(contentsOf: url) else {
            return
        }

        let prompt = prefilledText.isEmpty
            ? "Beskriv hvad du ser på dette billede."
            : prefilledText

        chatSession.addUserMessage("🖼 \(url.lastPathComponent)\n\(prompt)")
        let placeholderID = chatSession.addAssistantMessage("")
        chatSession.isStreaming = true
        defer { chatSession.isStreaming = false }

        let result = await geminiClient.sendTextWithImage(
            prompt: prompt,
            mode: BuiltInModes.vision,
            imageData: imageData
        )
        switch result {
        case .success(let text):
            chatSession.updateAssistant(id: placeholderID, text: text)
        case .failure(let error):
            chatSession.markAssistantError(
                id: placeholderID,
                errorText: RouterError.geminiFailed(error).errorDescription ?? "AI-kald fejlede.",
                sourceModeID: BuiltInModes.vision.id,
                sourcePrompt: prompt
            )
        }
    }

    private func runDroppedDocument(url: URL) async {
        let prompt = "📄 \(url.lastPathComponent) — opsummer dette dokument"
        chatSession.addUserMessage(prompt)
        let placeholderID = chatSession.addAssistantMessage("")
        chatSession.isStreaming = true
        defer { chatSession.isStreaming = false }

        do {
            let summary = try await summaryService.summarizeForChat(url: url)
            chatSession.updateAssistant(id: placeholderID, text: summary)
        } catch {
            chatSession.markAssistantError(
                id: placeholderID,
                errorText: RouterError.summaryFailed(error).errorDescription ?? "Opsummering fejlede.",
                sourceModeID: BuiltInModes.summarize.id,
                sourcePrompt: prompt
            )
        }
    }

    // MARK: - Document (Summarize)

    private func runSummarize(mode: Mode) async {
        guard let url = DocumentPicker.pickDocument() else { return }

        let prompt = "📄 \(url.lastPathComponent) — opsummer dette dokument"
        chatSession.addUserMessage(prompt)
        let placeholderID = chatSession.addAssistantMessage("")
        chatSession.isStreaming = true
        defer { chatSession.isStreaming = false }

        do {
            let summary = try await summaryService.summarizeForChat(url: url)
            chatSession.updateAssistant(id: placeholderID, text: summary)
        } catch {
            chatSession.markAssistantError(
                id: placeholderID,
                errorText: RouterError.summaryFailed(error).errorDescription ?? "Opsummering fejlede.",
                sourceModeID: mode.id,
                sourcePrompt: prompt
            )
        }
    }

    // MARK: - Retry

    /// Re-run the original (mode, prompt) for a failed assistant message.
    /// Overwrites the failed bubble in place so the history stays clean.
    func retry(_ message: ChatMessage) async {
        guard message.lastError != nil,
              let modeID = message.sourceModeID,
              let prompt = message.sourcePrompt else { return }

        // Look up the mode fresh — user may have edited the prompt/systemPrompt
        // since the original call. Fall back to the built-in map.
        let mode = BuiltInModes.all.first(where: { $0.id == modeID }) ?? BuiltInModes.chat

        chatSession.clearAssistantError(id: message.id)
        chatSession.isStreaming = true

        switch mode.inputKind {
        case .text:
            await retryText(message: message, mode: mode, prompt: prompt)
        case .screenshot:
            await retryScreenshot(message: message, mode: mode, prompt: prompt)
        case .document, .voice:
            // Document retry would re-open the file picker (user may have moved
            // the file) — skip for α.1. Voice retry doesn't apply.
            chatSession.isStreaming = false
        }
    }

    private func retryText(message: ChatMessage, mode: Mode, prompt: String) async {
        let pipeline = (mode.provider != .gemini && mode.agentTools)
            ? agentChatPipeline(mode.provider)
            : nil

        if let agent = pipeline {
            agent.sendTextMessage(prompt)
        } else {
            // Reuse the streaming endpoint directly so we overwrite the same
            // bubble instead of creating a new one.
            chatSession.updateAssistant(id: message.id, text: "")
            let result = await geminiClient.sendText(prompt: prompt, mode: mode)
            switch result {
            case .success(let text):
                chatSession.updateAssistant(id: message.id, text: text)
            case .failure(let error):
                chatSession.markAssistantError(
                    id: message.id,
                    errorText: "Fejl: \(error.localizedDescription)",
                    sourceModeID: mode.id,
                    sourcePrompt: prompt
                )
            }
            chatSession.isStreaming = false
        }
    }

    private func retryScreenshot(message: ChatMessage, mode: Mode, prompt: String) async {
        defer { chatSession.isStreaming = false }
        chatSession.updateAssistant(id: message.id, text: "")
        do {
            let imageData = try await screenCapture.captureActiveWindow()
            let result = await geminiClient.sendTextWithImage(
                prompt: prompt,
                mode: mode,
                imageData: imageData
            )
            switch result {
            case .success(let text):
                chatSession.updateAssistant(id: message.id, text: text)
            case .failure(let error):
                chatSession.markAssistantError(
                    id: message.id,
                    errorText: RouterError.geminiFailed(error).errorDescription ?? "AI-kald fejlede.",
                    sourceModeID: mode.id,
                    sourcePrompt: prompt
                )
            }
        } catch {
            chatSession.markAssistantError(
                id: message.id,
                errorText: RouterError.screenCaptureFailed(error).errorDescription ?? "Skærmfangst fejlede.",
                sourceModeID: mode.id,
                sourcePrompt: prompt
            )
        }
    }
}
