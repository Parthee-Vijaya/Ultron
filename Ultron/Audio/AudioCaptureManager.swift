import AVFoundation

/// Records microphone audio to WAV via `SharedAudioEngine`. In α.7 the audio
/// append path bounced through `Task { @MainActor }` which meant buffers
/// arriving right at stopRecording could be dropped (see the 44-byte "empty"
/// recordings in the log). v5.0.0-alpha.8 serialises audioData writes through
/// a private DispatchQueue so the audio thread can append directly without
/// waiting for main-actor scheduling.
@MainActor
class AudioCaptureManager {
    /// Serial queue that guards every read/write of `audioData`. Runs off the
    /// main actor so the audio-render thread can append without bouncing.
    nonisolated(unsafe) private var audioData = Data()
    private let audioQueue = DispatchQueue(label: "pavi.Ultron.AudioCapture.write",
                                           qos: .userInitiated)

    private var isRecording = false
    private var subscriberToken: UUID?
    private var bufferWarningLogged = false
    private static let bufferWarnThresholdBytes = 10 * 1_024 * 1_024

    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((Data) -> Void)?

    weak var levelMonitor: AudioLevelMonitor?
    weak var waveformBuffer: WaveformBuffer?

    func startRecording() throws {
        guard !isRecording else { return }
        let engine = SharedAudioEngine.shared
        try engine.start()

        guard let format = engine.inputFormat, format.sampleRate > 0 else {
            throw UltronError.audioFormatInvalid
        }

        // Reset buffer + write WAV header synchronously. Using audioQueue.sync
        // here so any pending audio-thread appends from a prior session have
        // drained before we start writing new ones.
        let header = createWAVHeader(
            dataSize: 0,
            sampleRate: format.sampleRate,
            channels: UInt16(format.channelCount)
        )
        audioQueue.sync {
            self.audioData = Data()
            self.audioData.append(header)
        }
        bufferWarningLogged = false

        subscriberToken = engine.addSubscriber { [weak self] buffer in
            self?.handleBuffer(buffer)
        }

        isRecording = true
        onRecordingStarted?()
        LoggingService.shared.log("Audio recording started (shared engine)")
    }

    func stopRecording() -> Data {
        guard isRecording else { return Data() }

        if let token = subscriberToken {
            SharedAudioEngine.shared.removeSubscriber(token)
            subscriberToken = nil
        }
        isRecording = false
        levelMonitor?.reset()
        waveformBuffer?.reset()

        // Flush + finalise on the same queue that owns audioData. sync ensures
        // any in-flight appends from the audio thread land first.
        let result: Data = audioQueue.sync {
            let dataSize = UInt32(max(0, self.audioData.count - 44))
            self.updateWAVHeader(data: &self.audioData, dataSize: dataSize)
            let snapshot = self.audioData
            self.audioData = Data()
            return snapshot
        }

        LoggingService.shared.log("Audio recording stopped (\(result.count) bytes)")
        onRecordingStopped?(result)
        return result
    }

    // MARK: - Audio-thread consumer

    nonisolated private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        var sumOfSquares: Float = 0
        var peak: Float = 0
        var pcm = Data(capacity: frameCount * 2)
        for i in 0..<frameCount {
            let sample = max(-1.0, min(1.0, channelData[i]))
            sumOfSquares += sample * sample
            if abs(sample) > abs(peak) { peak = sample }
            var intSample = Int16(sample * Float(Int16.max))
            pcm.append(Data(bytes: &intSample, count: 2))
        }

        let rms = frameCount > 0 ? sqrt(sumOfSquares / Float(frameCount)) : 0
        let boostedRMS = min(1.0, Double(rms) * 3.0)
        let oscPeak = max(-1.0, min(1.0, peak * 2.5))

        // Append PCM directly on the audio queue — no main-actor bounce.
        // subscriber removal on stopRecording guarantees no callback races the
        // flush, so it's safe to skip the `isRecording` gate here.
        audioQueue.async { [pcm] in
            self.audioData.append(pcm)
            if !self.bufferWarningLogged && self.audioData.count > Self.bufferWarnThresholdBytes {
                self.bufferWarningLogged = true
                LoggingService.shared.log("Audio buffer exceeded \(Self.bufferWarnThresholdBytes / 1_048_576) MB — approaching max duration", level: .warning)
            }
        }

        // Level + waveform UI bounce stays — they're main-actor-only observables.
        Task { @MainActor [weak self] in
            self?.levelMonitor?.submit(rms: boostedRMS)
            self?.waveformBuffer?.push(peak: oscPeak)
        }
    }

    // MARK: - WAV header helpers

    private func createWAVHeader(dataSize: UInt32, sampleRate: Double, channels: UInt16) -> Data {
        var header = Data()
        let sr = UInt32(sampleRate)
        let bitsPerSample: UInt16 = 16
        let byteRate = sr * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        header.append(contentsOf: "RIFF".utf8)
        var chunkSize = UInt32(36 + dataSize)
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append(contentsOf: "WAVE".utf8)

        header.append(contentsOf: "fmt ".utf8)
        var subchunk1Size: UInt32 = 16
        header.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: UInt16 = 1
        header.append(Data(bytes: &audioFormat, count: 2))
        var ch = channels
        header.append(Data(bytes: &ch, count: 2))
        var srVal = sr
        header.append(Data(bytes: &srVal, count: 4))
        var br = byteRate
        header.append(Data(bytes: &br, count: 4))
        var ba = blockAlign
        header.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample
        header.append(Data(bytes: &bps, count: 2))

        header.append(contentsOf: "data".utf8)
        var ds = dataSize
        header.append(Data(bytes: &ds, count: 4))
        return header
    }

    private func updateWAVHeader(data: inout Data, dataSize: UInt32) {
        guard data.count >= 44 else { return }
        var chunkSize = UInt32(36 + dataSize)
        data.replaceSubrange(4..<8, with: Data(bytes: &chunkSize, count: 4))
        var ds = dataSize
        data.replaceSubrange(40..<44, with: Data(bytes: &ds, count: 4))
    }
}
