import Foundation
import Observation

/// Running audio level (0...1) the mic tap can feed into and the HUD reads from.
/// Lives here (not inside AudioCaptureManager) so SwiftUI can observe it without
/// having to observe the whole capture manager.
///
/// `@MainActor` is required: the mic tap runs on an AVAudio render thread and must
/// dispatch to main before calling `submit(rms:)`. The isolation forces that contract
/// at compile time and prevents a data race on `level`.
@MainActor
@Observable
final class AudioLevelMonitor {
    /// Smoothed RMS level clamped to 0...1. 0 = silence, 1 = clipping.
    var level: Double = 0

    /// True when the smoothed level has been below `silenceThreshold` for longer than
    /// `silenceHintDelay` seconds. Resets instantly when voice returns. Drives the HUD
    /// "Slip for at sende" hint.
    var isSilent: Bool = false

    /// Threshold below which we consider the mic "silent". 0.02 is roughly ambient-room noise.
    var silenceThreshold: Double = 0.04
    /// Seconds of continuous silence before `isSilent` flips true.
    var silenceHintDelay: TimeInterval = 2.0

    private var silenceStart: Date?

    func submit(rms: Double) {
        let clamped = max(0, min(1, rms))
        // Fast attack, slower decay so transient peaks are visible but bars don't hold on.
        if clamped > level {
            level = level + (clamped - level) * 0.6
        } else {
            level = level + (clamped - level) * 0.2
        }

        // Track silence duration.
        if level < silenceThreshold {
            if silenceStart == nil {
                silenceStart = Date()
            } else if let start = silenceStart,
                      Date().timeIntervalSince(start) >= silenceHintDelay {
                if !isSilent { isSilent = true }
            }
        } else {
            silenceStart = nil
            if isSilent { isSilent = false }
        }
    }

    func reset() {
        level = 0
        isSilent = false
        silenceStart = nil
    }
}
