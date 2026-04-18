import AVFoundation

enum Constants {
    // MARK: - App
    static let appName = "Jarvis"
    static let appVersion = "4.1"
    static let bundleID = "pavi.Jarvis"

    // MARK: - Keychain
    static let keychainService = "pavi.Jarvis"
    static let keychainAccount = "GeminiAPIKey"
    static let keychainPorcupineAccount = "PorcupineAccessKey"

    // MARK: - Recording
    static let maxRecordingDuration: TimeInterval = 60
    static let audioBufferSize: AVAudioFrameCount = 4096
    static let audioBitsPerSample: UInt16 = 16

    // MARK: - HUD Dimensions
    enum HUD {
        static let width: CGFloat = 380
        static let minHeight: CGFloat = 120
        static let maxHeight: CGFloat = 400
        static let padding: CGFloat = 20
        static let cornerRadius: CGFloat = 16
        static let borderOpacity: Double = 0.2
        static let outerShadowRadius: CGFloat = 20
        static let outerShadowY: CGFloat = 10
        static let innerShadowRadius: CGFloat = 4
        static let innerShadowY: CGFloat = 2
    }

    // MARK: - Animation
    enum Animation {
        static let appearDuration: Double = 0.5
        static let appearBounce: Double = 0.6
        static let appearScaleFrom: CGFloat = 0.92
        static let appearOffsetFrom: CGFloat = 8
        static let waveformBarCount = 5
        static let waveformBarWidth: CGFloat = 4
        static let waveformBarMaxHeight: CGFloat = 24
        static let waveformAnimationDuration: Double = 0.4
    }

    // MARK: - Timers
    enum Timers {
        static let confirmationAutoClose: TimeInterval = 3
        static let resultAutoClose: TimeInterval = 30
        static let errorAutoClose: TimeInterval = 10
    }

    // MARK: - Cost
    static let costWarningThresholdUSD: Double = 1.00

    // MARK: - Retry
    enum Retry {
        static let maxAttempts = 3
        static let baseDelay: TimeInterval = 1.0
        static let backoffMultiplier: Double = 2.0
    }

    // MARK: - Crash Recovery
    static let crashRecoveryKey = "JarvisPipelineState"

    // MARK: - Chat HUD Dimensions
    enum ChatHUD {
        static let width: CGFloat = 420
        static let height: CGFloat = 520
        static let minWidth: CGFloat = 320
        static let minHeight: CGFloat = 400
    }

    // MARK: - UserDefaults Keys
    enum Defaults {
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let ttsEnabled = "ttsEnabled"
        static let hudPinned = "hudPinned"
        static let chatFrameX = "chatFrameX"
        static let chatFrameY = "chatFrameY"
        static let chatFrameW = "chatFrameW"
        static let chatFrameH = "chatFrameH"
        static let wakeWordEnabled = "wakeWordEnabled"
        static let hudStyle = "hudStyle"
    }

    // MARK: - Notch HUD dimensions
    enum NotchHUD {
        /// Width of the pill when showing processing (matches notch width).
        static let collapsedWidth: CGFloat = 240
        /// Width when showing recording / result content.
        static let expandedWidth: CGFloat = 460
        /// Max height when result text is long.
        static let maxHeight: CGFloat = 320
        /// Corner radius on the bottom of the pill — pairs visually with the notch cutout.
        static let cornerRadius: CGFloat = 22
        /// Overlap into the notch (pixels we push above notch bottom) to hide the seam.
        static let notchOverlap: CGFloat = 6
    }

    // MARK: - Gemini Models
    enum GeminiModelName {
        static let flash = "gemini-2.5-flash"
        static let pro = "gemini-2.5-pro"
    }
}
