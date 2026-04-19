import Foundation

/// Protocol for any engine that converts captured audio to text locally (no
/// network). In v1.3 there's one real implementation (WhisperKit, gated by
/// `#if canImport(WhisperKit)`), and `NoOpLocalTranscriber` is used when the
/// package isn't wired into the Xcode project yet — that keeps the app
/// buildable before the user adds the SPM dependency.
///
/// All implementations should be actor-isolated: transcription is CPU-heavy
/// and we never want it to block the main thread.
protocol LocalTranscriber: Sendable {
    /// True once the engine has loaded its model into memory and is ready
    /// to accept audio. UI should show a disabled/fallback state until true.
    var isReady: Bool { get async }

    /// Preload the underlying model. Call at app start so the first real
    /// transcription doesn't pay the load penalty.
    func preload() async throws

    /// Transcribe a full WAV/PCM blob at once. Returns the text (possibly
    /// empty if the audio is silent).
    func transcribe(audioData: Data, language: String?) async throws -> String
}

/// Used when no real local transcriber is available (e.g. before the user
/// adds the WhisperKit SPM package). Always returns empty string. Callers
/// should detect `isReady == false` and fall back to the remote path.
actor NoOpLocalTranscriber: LocalTranscriber {
    var isReady: Bool { false }
    func preload() async throws {}
    func transcribe(audioData: Data, language: String?) async throws -> String { "" }
}

/// Factory that returns whichever real implementation is compiled in, or the
/// no-op one otherwise. Callers (RecordingPipeline) use this instead of
/// instantiating a specific type directly.
enum LocalTranscribers {
    static func makeDefault() -> any LocalTranscriber {
        #if canImport(WhisperKit)
        return WhisperKitTranscriber()
        #else
        return NoOpLocalTranscriber()
        #endif
    }
}
