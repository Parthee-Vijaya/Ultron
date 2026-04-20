import Foundation

/// Decorator that wraps any `AIProvider` and emits a `TraceEntry` per call.
///
/// Usage at the call site:
/// ```swift
/// let traced = TracedAIProvider(inner: OllamaProvider(), type: .ollama, taskType: "digest")
/// pipeline.sendTextMessage(..., provider: traced)
/// ```
///
/// Transparent to callers — `send()` and `stream()` just add timing + token
/// counting around the inner call.
final class TracedAIProvider: AIProvider {
    private let inner: AIProvider
    private let providerType: AIProviderType
    private let taskType: String
    /// Free-form reason string captured by ProviderRouter. Empty when the
    /// call came through a non-routed provider.
    private let reason: String

    init(inner: AIProvider, type: AIProviderType, taskType: String, reason: String = "") {
        self.inner = inner
        self.providerType = type
        self.taskType = taskType
        self.reason = reason
    }

    func send(model: String, messages: [AIMessage], options: AIRequestOptions) async throws -> AIResponse {
        let start = Date()
        do {
            let response = try await inner.send(model: model, messages: messages, options: options)
            emit(model: model,
                 tokensIn: response.inputTokens,
                 tokensOut: response.outputTokens,
                 latencyMs: Int(start.distance(to: Date()) * 1000),
                 error: nil)
            return response
        } catch {
            emit(model: model,
                 tokensIn: 0, tokensOut: 0,
                 latencyMs: Int(start.distance(to: Date()) * 1000),
                 error: error)
            throw error
        }
    }

    func stream(model: String, messages: [AIMessage], options: AIRequestOptions) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let start = Date()
            let upstream = inner.stream(model: model, messages: messages, options: options)
            let task = Task {
                var tokensIn = 0
                var tokensOut = 0
                do {
                    for try await chunk in upstream {
                        if case .usage(let ti, let to) = chunk {
                            tokensIn = ti
                            tokensOut = to
                        }
                        continuation.yield(chunk)
                    }
                    emit(model: model,
                         tokensIn: tokensIn, tokensOut: tokensOut,
                         latencyMs: Int(start.distance(to: Date()) * 1000),
                         error: nil)
                    continuation.finish()
                } catch {
                    emit(model: model,
                         tokensIn: tokensIn, tokensOut: tokensOut,
                         latencyMs: Int(start.distance(to: Date()) * 1000),
                         error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func emit(model: String, tokensIn: Int, tokensOut: Int, latencyMs: Int, error: Error?) {
        // Hop off the isolation context to read the energy estimate + write
        // the trace entry. TraceStore.append is already nonisolated-safe.
        let type = providerType
        let task = taskType
        let reason = reason
        Task { @MainActor in
            let joules = EnergyMonitor.shared.estimateJoules(
                provider: type, model: model, tokensOut: tokensOut
            )
            let entry = TraceEntry(
                id: UUID(),
                timestamp: Date(),
                provider: type.rawValue,
                model: model,
                taskType: task,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                latencyMs: latencyMs,
                joulesEst: joules,
                reason: reason,
                rating: 0,
                errorDescription: error?.localizedDescription
            )
            TraceStore.shared.append(entry)
        }
    }
}
