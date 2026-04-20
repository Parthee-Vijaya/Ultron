import Foundation
import SwiftUI

/// A single stage Ultron is currently working through. Emitted by the voice +
/// chat + agent pipelines so the HUD and chat can narrate "what I'm doing"
/// instead of just showing a spinner.
///
/// The design is forward-compatible with the planned V2 UX overhaul: each step
/// carries a `kind` enum with rich associated values (provider name, query,
/// tool name, source count) so a future timeline UI can render per-step
/// check-marks + elapsed timing without changing the emit surface.
struct ProcessingStep: Equatable, Sendable {
    let kind: Kind
    let startedAt: Date

    init(_ kind: Kind, startedAt: Date = Date()) {
        self.kind = kind
        self.startedAt = startedAt
    }

    /// What the pipeline is currently doing. One-of at any moment; future
    /// versions may keep a timeline array, but for v1.4 we only surface the
    /// most recent active step.
    enum Kind: Equatable, Sendable {
        case transcribing(transport: String)       // "Transkriberer med Whisper / Gemini"
        case thinking(provider: String)            // "Spørger Gemini / Claude…"
        case streaming(provider: String)           // "Modtager svar…"
        case searchingWeb(query: String?)          // "Søger på nettet…"
        case readingSources(count: Int)            // "Læser 3 kilder…"
        case capturingScreen                       // "Tager screenshot…"
        case runningTool(name: String)             // "Kører værktøj: read_file"
        case formulating                           // "Formulerer svar…"
        case speaking                              // TTS playback
    }

    /// User-facing copy. Danish, noun-phrase + ellipsis, short enough to fit
    /// in a HUD subtitle or a chat status line.
    var displayText: String {
        switch kind {
        case .transcribing(let transport):
            switch transport {
            case "local-whisper": return "Transkriberer lokalt…"
            case "gemini-audio":  return "Gemini transkriberer…"
            default:              return "Transkriberer…"
            }
        case .thinking(let provider):
            return "\(provider) tænker…"
        case .streaming(let provider):
            return "Modtager svar fra \(provider)…"
        case .searchingWeb(let query):
            if let query, !query.isEmpty {
                let trimmed = query.count > 32 ? String(query.prefix(32)) + "…" : query
                return "Søger: \(trimmed)"
            }
            return "Søger på nettet…"
        case .readingSources(let count):
            return count == 1 ? "Læser 1 kilde…" : "Læser \(count) kilder…"
        case .capturingScreen:
            return "Tager screenshot…"
        case .runningTool(let name):
            return "Kører \(name)…"
        case .formulating:
            return "Formulerer svar…"
        case .speaking:
            return "Læser op…"
        }
    }

    /// SF Symbol for the HUD / chat icon slot. Chosen so the icon conveys the
    /// stage category even before the text is read.
    var icon: String {
        switch kind {
        case .transcribing:     return "waveform"
        case .thinking:         return "brain.head.profile"
        case .streaming:        return "arrow.down.circle.dotted"
        case .searchingWeb:     return "magnifyingglass"
        case .readingSources:   return "doc.text.magnifyingglass"
        case .capturingScreen:  return "camera.viewfinder"
        case .runningTool:      return "wrench.and.screwdriver"
        case .formulating:      return "text.bubble"
        case .speaking:         return "speaker.wave.2"
        }
    }
}
