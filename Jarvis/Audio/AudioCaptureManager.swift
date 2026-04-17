import AVFoundation

class AudioCaptureManager {
    private var audioEngine: AVAudioEngine?
    private var audioData = Data()
    private var isRecording = false

    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((Data) -> Void)?

    func startRecording() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        audioData = Data()
        audioData.append(createWAVHeader(dataSize: 0, sampleRate: format.sampleRate, channels: UInt16(format.channelCount)))

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let channelData = buffer.floatChannelData?[0]
            let frameCount = Int(buffer.frameLength)

            for i in 0..<frameCount {
                let sample = max(-1.0, min(1.0, channelData?[i] ?? 0))
                var intSample = Int16(sample * Float(Int16.max))
                self.audioData.append(Data(bytes: &intSample, count: 2))
            }
        }

        try engine.start()
        audioEngine = engine
        isRecording = true
        onRecordingStarted?()
        LoggingService.shared.log("Audio recording started")
    }

    func stopRecording() -> Data {
        guard isRecording, let engine = audioEngine else { return Data() }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        isRecording = false

        let dataSize = UInt32(audioData.count - 44)
        updateWAVHeader(data: &audioData, dataSize: dataSize)

        let result = audioData
        audioData = Data()

        LoggingService.shared.log("Audio recording stopped (\(result.count) bytes)")
        onRecordingStopped?(result)
        return result
    }

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
        var chunkSize = UInt32(36 + dataSize)
        data.replaceSubrange(4..<8, with: Data(bytes: &chunkSize, count: 4))
        var ds = dataSize
        data.replaceSubrange(40..<44, with: Data(bytes: &ds, count: 4))
    }
}
