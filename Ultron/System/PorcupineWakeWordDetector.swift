import AVFoundation
import Foundation

#if canImport(Porcupine)
import Porcupine
#endif

/// On-device "Ultron" wake-word detector using Picovoice Porcupine.
///
/// ## Setup (required for the detector to actually work)
/// 1. In Xcode: **File → Add Package Dependencies…**
/// 2. Paste: `https://github.com/Picovoice/porcupine`
/// 3. Choose the **Porcupine** product and add it to the Ultron target.
/// 4. Get a free AccessKey at <https://picovoice.ai/console/> and paste it into
///    Settings → Wake Word.
///
/// Until step 1–3 is done, `start()` throws `WakeWordError.porcupineNotIntegrated` so the
/// rest of the app stays functional. After the SPM dependency lands, the `#if canImport`
/// block below activates automatically — no other code changes needed.
///
/// ## Privacy
/// Audio is processed entirely on-device. No frames are ever sent off the machine.
/// Sub-1% CPU continuously on Apple Silicon.
final class PorcupineWakeWordDetector: WakeWordDetecting {
    private let accessKeyProvider: () -> String?
    private let audioEngine = AVAudioEngine()
    private var isActive = false

    #if canImport(Porcupine)
    private var porcupine: Porcupine?
    private var pendingBuffer: [Int16] = []
    private var frameLength: Int = 512  // Porcupine default for 16 kHz
    #endif

    private var onWake: (@MainActor () -> Void)?

    var isRunning: Bool { isActive }

    init(accessKeyProvider: @escaping () -> String?) {
        self.accessKeyProvider = accessKeyProvider
    }

    deinit {
        stop()
    }

    func start(onWake: @escaping @MainActor () -> Void) throws {
        guard !isActive else { return }
        self.onWake = onWake

        #if canImport(Porcupine)
        guard let accessKey = accessKeyProvider(), !accessKey.isEmpty else {
            throw WakeWordError.missingAccessKey
        }

        do {
            // "ultron" is one of Porcupine's built-in free keywords — no custom .ppn needed.
            porcupine = try Porcupine(accessKey: accessKey, keyword: .ultron)
            frameLength = Porcupine.frameLength
        } catch {
            throw WakeWordError.initializationFailed(underlying: error)
        }

        try installAudioTap()
        try audioEngine.start()
        isActive = true
        LoggingService.shared.log("Wake word detector started (Porcupine, 'ultron' keyword)")
        #else
        throw WakeWordError.porcupineNotIntegrated
        #endif
    }

    func stop() {
        guard isActive else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        #if canImport(Porcupine)
        try? porcupine?.delete()
        porcupine = nil
        pendingBuffer.removeAll()
        #endif
        isActive = false
        LoggingService.shared.log("Wake word detector stopped")
    }

    // MARK: - Private

    #if canImport(Porcupine)
    private func installAudioTap() throws {
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: Double(Porcupine.sampleRate),
                                               channels: 1,
                                               interleaved: true) else {
            throw WakeWordError.audioEngineFailed(underlying: NSError(domain: "WakeWord", code: 1))
        }

        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let converter else { return }

            let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) *
                                                   Double(targetFormat.sampleRate) /
                                                   buffer.format.sampleRate) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                status.pointee = consumed ? .noDataNow : .haveData
                consumed = true
                return buffer
            }
            if error != nil { return }

            self.feedPorcupine(converted)
        }
    }

    private func feedPorcupine(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        pendingBuffer.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))

        while pendingBuffer.count >= frameLength {
            let frame = Array(pendingBuffer.prefix(frameLength))
            pendingBuffer.removeFirst(frameLength)
            do {
                guard let porcupine else { return }
                let keywordIndex = try porcupine.process(pcm: frame)
                if keywordIndex >= 0 {
                    LoggingService.shared.log("Wake word detected: 'ultron'")
                    let handler = onWake
                    Task { @MainActor in
                        handler?()
                    }
                }
            } catch {
                LoggingService.shared.log("Porcupine process error: \(error)", level: .error)
            }
        }
    }
    #endif
}
