import AVFoundation

class TTSService {
    private let synthesizer = AVSpeechSynthesizer()

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "ttsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "ttsEnabled") }
    }

    func speak(_ text: String, language: String = "da-DK") {
        guard isEnabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    func speakAlways(_ text: String, language: String = "da-DK") {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
