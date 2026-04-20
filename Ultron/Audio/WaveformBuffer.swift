import Foundation
import Observation

/// Rolling waveform samples for the HUD oscilloscope. Holds ~2 seconds of audio
/// downsampled to a fixed number of display buckets, so SwiftUI doesn't have to
/// render 96 000 points per frame. The mic tap pushes peaks here at ~20 Hz.
///
/// Stored as signed floats in -1...1. Reading views tile them left-to-right as a
/// rolling strip (oldest → newest).
@MainActor
@Observable
final class WaveformBuffer {
    /// How many display buckets we maintain. 200 = 100 ms per bucket for 20s of history,
    /// or 10 ms per bucket for 2s — we use the latter.
    static let displaySampleCount = 200

    /// Public read-only snapshot. Newest sample is last.
    private(set) var samples: [Float] = Array(repeating: 0, count: displaySampleCount)

    /// Append one bucket. The bucket value should be the peak (or RMS) of the audio
    /// chunk the tap just processed. Clamps to -1...1.
    func push(peak: Float) {
        let clamped = max(-1, min(1, peak))
        samples.removeFirst()
        samples.append(clamped)
    }

    func reset() {
        samples = Array(repeating: 0, count: Self.displaySampleCount)
    }
}
