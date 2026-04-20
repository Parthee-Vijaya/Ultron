import Foundation

extension Notification.Name {
    /// Fired when the user toggles the wake-word setting or saves a new AccessKey.
    /// AppDelegate listens and restarts (or stops) the detector accordingly.
    static let ultronWakeWordSettingsChanged = Notification.Name("ultronWakeWordSettingsChanged")

    /// Fired when the continuous "Ultron ..." voice-command toggle flips.
    static let ultronVoiceCommandSettingsChanged = Notification.Name("ultronVoiceCommandSettingsChanged")
}
