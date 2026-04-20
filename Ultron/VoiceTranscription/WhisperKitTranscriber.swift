import Foundation
import SwiftUI

#if canImport(WhisperKit)
import WhisperKit

/// Observable state for the one-time WhisperKit model preload. Written to by
/// `WhisperKitTranscriber.preload()`, read by the HUD and Settings panes.
///
/// Kept MainActor-bound so SwiftUI's `@Observable` diffing sees every mutation
/// on the UI thread without hopping. The transcriber calls into this via
/// `MainActor.run` from its background preload task.
@MainActor
@Observable
final class WhisperPreloadState {
    enum Phase: Equatable {
        case idle
        case downloading
        case warming
        case ready
        case failed(String)
    }

    static let shared = WhisperPreloadState()

    var phase: Phase = .idle
    var progress: Double = 0.0   // 0.0...1.0 during `.downloading`

    private init() {}
}

/// Local speech-to-text via WhisperKit (https://github.com/argmaxinc/WhisperKit).
///
/// Designed to be a drop-in replacement for the Gemini audio-transcription
/// call in `RecordingPipeline`. On an M-series Mac with `distil-whisper-small`
/// we expect ~700 ms end-to-end for a 5 s utterance, with Danish supported
/// out of the box.
///
/// Model is downloaded on first `preload()` call; subsequent launches reuse
/// the cached CoreML bundle from WhisperKit's default cache directory
/// (`~/Library/Application Support/argmaxinc/WhisperKit/`).
actor WhisperKitTranscriber: LocalTranscriber {
    private var whisper: WhisperKit?
    private(set) var isReadyState: Bool = false

    var isReady: Bool { isReadyState }

    /// Shared preload state surface. Nonisolated because `WhisperPreloadState`
    /// is a MainActor type — callers read it from SwiftUI views directly.
    nonisolated static var preloadState: WhisperPreloadState { WhisperPreloadState.shared }

    /// Preload the model. Safe to call repeatedly — second and later calls
    /// return instantly once the WhisperKit instance is cached.
    ///
    /// First call on a fresh install downloads the model (~632 MB). We drive
    /// `WhisperPreloadState.shared` so the UI (Cockpit chip + Settings row)
    /// can render download progress. Subsequent launches hit the cache and
    /// skip straight to `.warming` then `.ready`.
    func preload() async throws {
        if whisper != nil { return }
        let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"
        LoggingService.shared.log("WhisperKit preload starting (model=\(modelName))…")
        await MainActor.run {
            WhisperPreloadState.shared.phase = .downloading
            WhisperPreloadState.shared.progress = 0.0
        }
        let start = ContinuousClock.now
        do {
            // 1) Download (no-op if cached). Pipe Progress.fractionCompleted
            //    into our MainActor state so the HUD can render it.
            let modelFolder = try await WhisperKit.download(
                variant: modelName,
                useBackgroundSession: false,
                from: "argmaxinc/whisperkit-coreml"
            ) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    WhisperPreloadState.shared.progress = fraction
                }
            }

            // 2) Now warm the model. `modelFolder` is already local, so this
            //    second init won't re-download.
            await MainActor.run {
                WhisperPreloadState.shared.phase = .warming
                WhisperPreloadState.shared.progress = 1.0
            }

            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .info,
                prewarm: true,
                load: true,
                download: false
            )
            let instance = try await WhisperKit(config)
            whisper = instance
            isReadyState = true

            await MainActor.run { WhisperPreloadState.shared.phase = .ready }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            LoggingService.shared.log(String(format: "WhisperKit ready in %.2fs (model=\(modelName))", seconds))
        } catch {
            let msg = (error as NSError).localizedDescription
            await MainActor.run { WhisperPreloadState.shared.phase = .failed(msg) }
            LoggingService.shared.log("WhisperKit preload failed: \(error)", level: .error)
            throw error
        }
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        guard let whisper else {
            throw TranscribeError.notReady
        }
        // WhisperKit expects a [Float] of 16 kHz PCM samples; the RecordingPipeline
        // captures at that rate so we can convert directly. Gemini-compatible
        // WAVs include a 44-byte header we need to skip.
        let samples = Self.wavToFloatSamples(audioData)
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - WAV → [Float]

    /// Convert a 16 kHz mono 16-bit PCM WAV blob into the `[Float]` WhisperKit
    /// expects. No resampling here — `AudioCaptureManager` already records at
    /// 16 kHz so the samples line up 1:1 with Whisper's input contract.
    private static func wavToFloatSamples(_ data: Data) -> [Float] {
        // Minimal WAV header sniff — skip the RIFF/fmt/data chunks until we
        // find the sample payload. AudioCaptureManager writes canonical WAVs
        // so the 44-byte default covers us, but we scan defensively.
        var offset = 12  // past "RIFFxxxxWAVE"
        while offset + 8 < data.count {
            let id = data.subdata(in: offset..<offset + 4)
            let size = data.withUnsafeBytes { ptr -> UInt32 in
                let base = ptr.baseAddress!.advanced(by: offset + 4)
                return base.loadUnaligned(as: UInt32.self)
            }
            if id == Data("data".utf8) {
                offset += 8
                break
            }
            offset += 8 + Int(size)
        }
        guard offset < data.count else { return [] }
        let sampleBytes = data.subdata(in: offset..<data.count)
        let sampleCount = sampleBytes.count / MemoryLayout<Int16>.size
        var samples = [Float](repeating: 0, count: sampleCount)
        sampleBytes.withUnsafeBytes { rawBuffer in
            let int16Pointer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Pointer[i]) / 32_768.0
            }
        }
        return samples
    }

    enum TranscribeError: Error, LocalizedError {
        case notReady
        var errorDescription: String? {
            switch self {
            case .notReady: return "WhisperKit model not yet loaded. Call preload() first."
            }
        }
    }
}

#else

// WhisperKit SPM package not added yet — this file intentionally contains no
// type when the import fails, so `LocalTranscribers.makeDefault()` falls back
// to `NoOpLocalTranscriber`. Once the user adds the package via
// Xcode → File → Add Package Dependencies → https://github.com/argmaxinc/WhisperKit
// this file becomes the real implementation automatically.

#endif
