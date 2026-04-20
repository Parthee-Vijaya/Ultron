import AVFoundation
import Foundation

/// A single shared `AVAudioEngine` that both the recording WAV writer and the
/// live speech-recognition service tap into. Pre-v5.0.0-alpha.4 we had two
/// independent engines both grabbing the mic, which caused extra latency (up
/// to ~100 ms between voice and level-meter response) and occasional missed
/// startup audio while the second engine spun up.
///
/// Usage:
/// - Call `start()` once any subscriber needs audio. Subsequent calls are no-ops.
/// - Subscribe with `addSubscriber(_:)` — the subscriber receives every tap
///   buffer on the audio thread. Heavy work should bounce to main or a worker.
/// - Unsubscribe with the token returned. When the last subscriber unsubscribes
///   the engine stays running only if `keepAlive` is true (voice-command mode);
///   otherwise it stops to save mic usage.
@MainActor
final class SharedAudioEngine {
    static let shared = SharedAudioEngine()

    /// Single-file configuration — buffer size tuned for snappy UX (~23 Hz level
    /// updates at 48 kHz, half of v4's 4096 frames).
    static let bufferSize: AVAudioFrameCount = 2048

    private let engine = AVAudioEngine()
    private var subscribers: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    private var tapInstalled = false
    private(set) var isRunning = false
    /// When true the engine keeps running even with zero subscribers — used by
    /// the voice-command listener's warm-up window so the first spoken command
    /// doesn't cold-start the mic.
    var keepAlive = false

    /// Format reported by the input node at tap-install time. Cached so subscribers
    /// don't have to re-query AVAudioEngine from random threads.
    private(set) var inputFormat: AVAudioFormat?

    private init() {}

    func start() throws {
        guard !isRunning else { return }
        installTapIfNeeded()
        try engine.start()
        isRunning = true
        LoggingService.shared.log("SharedAudioEngine started (bufferSize=\(Self.bufferSize))")
    }

    func stopIfIdle() {
        guard subscribers.isEmpty, !keepAlive else { return }
        actuallyStop()
    }

    func forceStop() {
        actuallyStop()
    }

    private func actuallyStop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapInstalled = false
        isRunning = false
        inputFormat = nil
        LoggingService.shared.log("SharedAudioEngine stopped")
    }

    @discardableResult
    func addSubscriber(_ handler: @escaping (AVAudioPCMBuffer) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        return token
    }

    func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
        if subscribers.isEmpty && !keepAlive { actuallyStop() }
    }

    // MARK: - Tap

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        self.inputFormat = format

        input.installTap(onBus: 0, bufferSize: Self.bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Pass the buffer to every subscriber. Work stays on the audio thread —
            // subscribers that need main-actor work are responsible for bouncing.
            let snapshot = self.subscribers
            for handler in snapshot.values {
                handler(buffer)
            }
        }
        tapInstalled = true
    }
}
