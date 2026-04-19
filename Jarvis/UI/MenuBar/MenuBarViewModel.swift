import Foundation
import Observation

/// v1.4 Fase 2c — scaffolding for the MenuBarExtra migration.
///
/// This is Step 1 of the 5-step plan: introduce an `@Observable` model that
/// AppDelegate can write to in parallel with the existing `NSStatusItem`.
/// The SwiftUI MenuBarExtra scene (coming in Step 3) will bind to this
/// model. During the transition period both the legacy NSMenu and the new
/// SwiftUI menu can coexist, reading the same source of truth.
///
/// Safe to land independently — no behaviour change until Step 3.
@MainActor
@Observable
final class MenuBarViewModel {
    /// Mirrors the RecordingPipeline's public state enum so the icon can
    /// render idle / recording / processing glyphs without importing the
    /// full pipeline surface into the SwiftUI layer.
    enum IconState: Equatable {
        case idle
        case recording
        case processing
    }

    /// What glyph the menu-bar chip should currently show. AppDelegate's
    /// `pipeline.onStateChanged` closure writes here whenever the recording
    /// pipeline's state changes.
    var iconState: IconState = .idle

    /// Human-readable mode name shown in the menu header row. Kept in sync
    /// by AppDelegate when `modeManager.activeMode` changes.
    var activeModeName: String = ""

    /// Formatted usage line ("Brugt: 0,12 USD") — pre-computed by
    /// UsageTracker so the menu doesn't need to know about token counts.
    var usageLabel: String = ""

    /// v1.4: inline text that replaces the mode name while the pipeline
    /// is recording or processing (matches the old NSStatusItem chip copy).
    /// Nil during idle; set to "Optager" / "Arbejder" / …  by AppDelegate.
    var statusChip: String? = nil
}
