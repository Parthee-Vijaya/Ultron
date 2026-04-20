import Foundation

/// Implements AIProvider by consulting `RoutingPolicy` at call time and
/// delegating to the appropriate concrete provider. Used by modes with
/// `provider = .auto`.
///
/// Holds weak references to a shared provider factory so each concrete
/// provider (Ollama, Anthropic, Gemini) is constructed once per app session.
@MainActor
final class ProviderRouter: AIProvider {
    nonisolated struct Factories: Sendable {
        let ollama: @Sendable () -> AIProvider
        let anthropic: @Sendable () -> AIProvider
        let gemini: @Sendable () -> AIProvider
    }

    private let factories: Factories
    private var ollamaCached: AIProvider?
    private var anthropicCached: AIProvider?
    private var geminiCached: AIProvider?

    /// Probe state is refreshed in the background; stale-but-recent values
    /// avoid hammering the daemon on every call.
    private var lastOllamaProbe: Date = .distantPast
    private var ollamaAvailable: Bool = false
    private static let probeTTL: TimeInterval = 15

    init(factories: Factories) {
        self.factories = factories
    }

    // MARK: - AIProvider conformance

    nonisolated func send(model: String, messages: [AIMessage], options: AIRequestOptions) async throws -> AIResponse {
        let (provider, reason) = await resolve(messages: messages, options: options)
        let traced = TracedAIProvider(
            inner: await innerProvider(for: provider),
            type: provider,
            taskType: "auto.send",
            reason: reason
        )
        let resolvedModel = await modelFor(provider: provider, requested: model)
        return try await traced.send(model: resolvedModel, messages: messages, options: options)
    }

    nonisolated func stream(model: String, messages: [AIMessage], options: AIRequestOptions) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let (provider, reason) = await self.resolve(messages: messages, options: options)
                let traced = TracedAIProvider(
                    inner: await self.innerProvider(for: provider),
                    type: provider,
                    taskType: "auto.stream",
                    reason: reason
                )
                let resolvedModel = await self.modelFor(provider: provider, requested: model)
                do {
                    for try await chunk in traced.stream(model: resolvedModel, messages: messages, options: options) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Routing internals

    private func resolve(messages: [AIMessage], options: AIRequestOptions) async -> (AIProviderType, String) {
        await refreshOllamaProbeIfStale()
        let hasVision = messages.contains { msg in
            msg.parts.contains { if case .image = $0 { return true } else { return false } }
        }
        let tokens = estimatedTokens(messages: messages, options: options)
        let battery = EnergyMonitor.shared.currentState()
        let inputs = RoutingPolicy.Inputs(
            taskType: "auto",
            hasVision: hasVision,
            hasToolUse: !options.tools.isEmpty,
            estimatedTokens: tokens,
            ollamaAvailable: ollamaAvailable,
            onBattery: !battery.onAC,
            batteryPercent: battery.chargePercent,
            userPreference: nil
        )
        let decision = RoutingPolicy.decide(inputs)
        return (decision.provider, decision.reason)
    }

    private func estimatedTokens(messages: [AIMessage], options: AIRequestOptions) -> Int {
        var chars = options.systemPrompt?.count ?? 0
        for msg in messages {
            for part in msg.parts {
                if case .text(let t) = part { chars += t.count }
            }
        }
        return chars / 4  // rough ~4 chars per token
    }

    private func innerProvider(for type: AIProviderType) -> AIProvider {
        switch type {
        case .ollama:
            if let cached = ollamaCached { return cached }
            let new = factories.ollama()
            ollamaCached = new
            return new
        case .anthropic:
            if let cached = anthropicCached { return cached }
            let new = factories.anthropic()
            anthropicCached = new
            return new
        case .gemini, .auto:
            if let cached = geminiCached { return cached }
            let new = factories.gemini()
            geminiCached = new
            return new
        }
    }

    /// Pick a concrete model id for the resolved provider. If the user asked
    /// for a Claude model and the router picked Ollama, swap to the Ollama
    /// preferred model — otherwise the Anthropic model id would fail.
    private func modelFor(provider: AIProviderType, requested: String) -> String {
        switch provider {
        case .ollama:
            return UserDefaults.standard.string(forKey: Constants.Defaults.agentOllamaModel)
                ?? "llama3.2:latest"
        case .anthropic:
            return UserDefaults.standard.string(forKey: Constants.Defaults.agentClaudeModel)
                ?? "claude-sonnet-4-6"
        case .gemini, .auto:
            // ChatPipeline historically uses "gemini-2.5-flash" — trust the
            // caller's requested id when it's already a gemini-family name.
            if requested.lowercased().contains("gemini") { return requested }
            return "gemini-2.5-flash"
        }
    }

    private func refreshOllamaProbeIfStale() async {
        if Date().timeIntervalSince(lastOllamaProbe) < Self.probeTTL { return }
        let models = await OllamaProvider.probeInstalledModels()
        lastOllamaProbe = Date()
        ollamaAvailable = (models?.isEmpty == false)
    }
}
