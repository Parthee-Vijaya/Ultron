import AVFoundation

enum Constants {
    // MARK: - App
    static let appName = "Jarvis"
    static let appVersion = "4.3.0"
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
        static let claudeDailyLimitTokens = "claudeDailyLimitTokens"
        static let claudeWeeklyLimitTokens = "claudeWeeklyLimitTokens"
    }

    // MARK: - Claude Code defaults
    enum ClaudeStats {
        /// Default daily budget shown in the Info panel when the user hasn't set one.
        /// 1 M tokens is a rough placeholder for "an intense day".
        static let defaultDailyLimit = 1_000_000
        /// Default weekly budget. Free/Pro users can override in Settings.
        static let defaultWeeklyLimit = 5_000_000
    }

    // MARK: - Notch HUD dimensions
    enum NotchHUD {
        /// Width for recording / processing — matches Apple's Dynamic Island-style layout
        /// on MacBooks where the pill extends roughly 3× the notch width.
        static let expandedWidth: CGFloat = 640
        /// Height during recording / processing.
        static let compactHeight: CGFloat = 150
        /// Height when showing a result block with wrapped text.
        static let resultHeight: CGFloat = 230
        /// Bottom-corner radius — tall + pronounced so it reads as an extension of the notch.
        static let cornerRadius: CGFloat = 32
        /// How many points we push the pill above the physical notch bottom to hide the seam.
        static let notchOverlap: CGFloat = 4
        /// Width of the left visualisation column (arc reactor + oscilloscope).
        static let visualColumnWidth: CGFloat = 84
    }

    // MARK: - Gemini Models
    enum GeminiModelName {
        static let flash = "gemini-2.5-flash"
        static let pro = "gemini-2.5-pro"
    }
}
