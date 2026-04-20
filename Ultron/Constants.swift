import AVFoundation

enum Constants {
    // MARK: - App
    /// Display name shown in UI. Code/bundle uses unstylised "Ultron" to avoid
    /// breaking Keychain-service IDs and log paths.
    static let displayName = "U.L.T.R.O.N"
    static let appName = "Ultron"
    static let appVersion = "1.4.0-alpha.1"
    static let bundleID = "pavi.Ultron"

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
    static let keychainService = "pavi.Ultron"
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
    static let crashRecoveryKey = "UltronPipelineState"

    // MARK: - Chat HUD Dimensions
    enum ChatHUD {
        /// Default size for the centered Spotlight-style chat window (β.11+).
        static let width: CGFloat = 720
        static let height: CGFloat = 520
        static let minWidth: CGFloat = 520
        static let minHeight: CGFloat = 360
    }

    // MARK: - UserDefaults Keys
    enum Defaults {
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let ttsEnabled = "ttsEnabled"
        static let hudPinned = "hudPinned"
        // Chat-frame keys removed in β.11 — window is now always centered.
        // Defaults left in place get overwritten by the centering logic.
        static let wakeWordEnabled = "wakeWordEnabled"
        static let voiceCommandsEnabled = "voiceCommandsEnabled"
        static let claudeDailyLimitTokens = "claudeDailyLimitTokens"
        static let claudeWeeklyLimitTokens = "claudeWeeklyLimitTokens"
        static let agentClaudeModel = "agentClaudeModel"
        /// v1.5 Phase 3a: which local Ollama model to use when a Mode's
        /// provider is `.ollama`. User picks from probed tags in Settings.
        static let agentOllamaModel = "agentOllamaModel"
        static let agentWorkspaceRoots = "agentWorkspaceRoots"
        /// v1.1.7: newline-separated list of additional program names the user
        /// trusts for `run_shell` beyond the built-in defaults.
        static let shellCommandWhitelist = "shellCommandWhitelist"
        /// v1.4: when true (default) HUDWindowController suppresses auto-pop
        /// surfaces (showResult/showError/showConfirmation/showPermissionError)
        /// while the system reports itself as quiet (screen locked or display
        /// asleep). Push-to-talk + user-opened panels always bypass this.
        static let respectFocusMode = "respectFocusMode"
    }

    // MARK: - Claude Code defaults
    enum ClaudeStats {
        /// Default daily budget shown in the Info panel when the user hasn't
        /// set one. Cache-read tokens dominate on agent-heavy days — 500 M
        /// tokens/day is a defensible "hard working" baseline. Users on the
        /// Claude Pro / Max / Team plans can bump this in Settings.
        static let defaultDailyLimit = 500_000_000
        /// Default weekly budget — 5 × daily. Anything above "week in the
        /// weeds" territory lands over the 100% mark, which the bar clamps
        /// to full + the text shows ">999%" instead of an alarming raw number.
        static let defaultWeeklyLimit = 2_500_000_000
    }


    // MARK: - Gemini Models
    enum GeminiModelName {
        static let flash = "gemini-2.5-flash"
        static let pro = "gemini-2.5-pro"
    }
}
