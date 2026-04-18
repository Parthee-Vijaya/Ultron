import SwiftUI

/// Claude-desktop-inspired palette. v5.0.0-alpha.5 retired the HAL 9000 red
/// theme in favour of a calmer dark-neutral surface with a warm amber accent
/// (Anthropic's signature Claude orange).
///
/// Legacy names from v4 (`neonCyan`, `brightCyan`, …) are kept as aliases so
/// existing view code compiles without changes; they now map to the Claude
/// equivalents.
enum JarvisTheme {
    // MARK: - Surfaces (dark neutrals, not pitch black)
    /// Primary HUD background. Slightly lighter than true black so it reads as
    /// a surface rather than a void.
    static let surfaceBase     = Color(red: 0.094, green: 0.094, blue: 0.102)   // #18181A
    /// Raised card / elevated element.
    static let surfaceElevated = Color(red: 0.133, green: 0.133, blue: 0.141)   // #222224
    /// Subtle hairline border colour.
    static let hairline        = Color.white.opacity(0.08)

    // MARK: - Accent (warm amber — "Claude orange")
    /// Primary action / highlight colour.
    static let accent          = Color(red: 0.851, green: 0.459, blue: 0.341)   // #D9755A
    /// Brighter variant for hover / emphasis.
    static let accentBright    = Color(red: 0.937, green: 0.553, blue: 0.404)   // #EF8C67
    /// Dimmer variant for secondary accents.
    static let accentMuted     = Color(red: 0.616, green: 0.306, blue: 0.200)   // #9D4E33

    // MARK: - Text
    static let textPrimary     = Color(red: 0.933, green: 0.933, blue: 0.929)   // #EEEEED
    static let textSecondary   = Color(red: 0.635, green: 0.635, blue: 0.627)   // #A2A2A0
    static let textMuted       = Color(red: 0.435, green: 0.435, blue: 0.427)   // #6F6F6D

    // MARK: - Semantic
    static let successGlow     = Color(red: 0.427, green: 0.741, blue: 0.510)   // #6DBD82
    static let warningGlow     = Color(red: 0.976, green: 0.706, blue: 0.341)   // #F9B457
    static let criticalGlow    = Color(red: 0.906, green: 0.396, blue: 0.365)   // #E7655D

    // MARK: - Legacy v4 aliases (kept so older views don't need rewrites)
    static var neonCyan: Color    { accent }
    static var brightCyan: Color  { accentBright }
    static var deepCyan: Color    { accentMuted }
    static var halRed: Color      { accent }
    static var halFlare: Color    { accentBright }
    static var halDeep: Color     { accentMuted }
    static var halBrass: Color    { accent }
    static var halWarning: Color  { warningGlow }

    // MARK: - Gradients
    static let surfaceGradient = LinearGradient(
        colors: [surfaceBase, surfaceElevated],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// Legacy alias (was deepSpaceGradient).
    static var deepSpaceGradient: LinearGradient { surfaceGradient }

    /// Subtle border glow when the HUD is active.
    static let borderGradient = LinearGradient(
        colors: [accent.opacity(0.35), hairline],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Used by the pulsing recording indicator dot.
    static let coreGradient = RadialGradient(
        colors: [accentBright, accent, accent.opacity(0)],
        center: .center,
        startRadius: 0,
        endRadius: 12
    )

    /// Chat user-message bubble.
    static let userBubble = LinearGradient(
        colors: [accent.opacity(0.85), accentMuted.opacity(0.7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
