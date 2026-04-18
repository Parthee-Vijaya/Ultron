import AVFoundation

enum Constants {
    // MARK: - App
    /// Display name shown in UI. Code/bundle uses unstylised "Jarvis" to avoid
    /// breaking Keychain-service IDs and log paths.
    static let displayName = "J.A.R.V.I.S"
    static let appName = "Jarvis"
    static let appVersion = "5.0.0-beta.3"
    static let bundleID = "pavi.Jarvis"

    // MARK: - Spacing scale (use these instead of magic numbers)
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat  = 4
        static let sm: CGFloat  = 8
        static let md: CGFloat  = 12
        static let lg: CGFloat  = 16
        static let xl: CGFloat  = 20
        static let xxl: CGFloat = 28
    }

    // MARK: - Settings window
    enum SettingsWindow {
        static let defaultWidth: CGFloat = 840
        static let defaultHeight: CGFloat = 620
        static let minWidth: CGFloat = 720
        static let minHeight: CGFloat = 520
        static let sidebarWidth: CGFloat = 200
    }

    // MARK: - Keychain
    static let keychainService = "pavi.Jarvis"
    static let keychainAccount = "GeminiAPIKey"
    static let keychainPorcupineAccount = "PorcupineAccessKey"
    static let keychainAnthropicAccount = "AnthropicAPIKey"

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
        static let voiceCommandsEnabled = "voiceCommandsEnabled"
        static let claudeDailyLimitTokens = "claudeDailyLimitTokens"
        static let claudeWeeklyLimitTokens = "claudeWeeklyLimitTokens"
        static let agentClaudeModel = "agentClaudeModel"
        static let agentWorkspaceRoots = "agentWorkspaceRoots"
    }

    // MARK: - Claude Code defaults
    enum ClaudeStats {
        /// Default daily budget shown in the Info panel when the user hasn't set one.
        /// 1 M tokens is a rough placeholder for "an intense day".
        static let defaultDailyLimit = 1_000_000
        /// Default weekly budget. Free/Pro users can override in Settings.
        static let defaultWeeklyLimit = 5_000_000
    }


    // MARK: - Gemini Models
    enum GeminiModelName {
        static let flash = "gemini-2.5-flash"
        static let pro = "gemini-2.5-pro"
    }
}
