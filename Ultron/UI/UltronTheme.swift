import AppKit
import SwiftUI

/// Claude-desktop-inspired palette. v1.4 (Fase 2a) split every colour into a
/// light + dark variant so the HUD is legible regardless of macOS appearance.
/// Light mode lands on a warm off-white surface instead of the dark neutral,
/// and text/accent tones flip for contrast.
///
/// Legacy v4 names (`neonCyan`, `brightCyan`, …) remain as computed aliases
/// so existing view code compiles without edits. They'll be removed in a
/// follow-up once the codebase has migrated to the semantic names.
enum UltronTheme {
    // MARK: - Surfaces
    /// Primary HUD background. Slightly lighter than true black on dark,
    /// a warm paper-white on light. The `.regularMaterial` in
    /// `UltronHUDBackground` sits on top of this so the surface mostly
    /// shows through macOS vibrancy.
    static let surfaceBase = Color(
        light: Color(red: 0.970, green: 0.968, blue: 0.964),   // #F7F7F6
        dark:  Color(red: 0.094, green: 0.094, blue: 0.102)    // #18181A
    )
    /// Raised card / elevated element.
    static let surfaceElevated = Color(
        light: Color(red: 0.933, green: 0.929, blue: 0.918),   // #EEEDEA
        dark:  Color(red: 0.133, green: 0.133, blue: 0.141)    // #222224
    )
    /// Subtle hairline border colour.
    static let hairline = Color(
        light: Color.black.opacity(0.10),
        dark:  Color.white.opacity(0.08)
    )

    // MARK: - Accent (warm amber — "Claude orange")
    /// Primary action / highlight colour. The light/dark variants shift
    /// the amber slightly cooler on light so it passes WCAG AA contrast
    /// against the off-white surface.
    static let accent = Color(
        light: Color(red: 0.769, green: 0.376, blue: 0.263),   // #C4603C  (deeper on light)
        dark:  Color(red: 0.851, green: 0.459, blue: 0.341)    // #D9755A  (brighter on dark)
    )
    /// Brighter variant for hover / emphasis.
    static let accentBright = Color(
        light: Color(red: 0.698, green: 0.322, blue: 0.216),   // #B25237
        dark:  Color(red: 0.937, green: 0.553, blue: 0.404)    // #EF8C67
    )
    /// Dimmer variant for secondary accents.
    static let accentMuted = Color(
        light: Color(red: 0.824, green: 0.533, blue: 0.443),   // #D28871  (washed on light)
        dark:  Color(red: 0.616, green: 0.306, blue: 0.200)    // #9D4E33
    )

    // MARK: - Text
    static let textPrimary = Color(
        light: Color(red: 0.090, green: 0.090, blue: 0.094),   // near-black
        dark:  Color(red: 0.933, green: 0.933, blue: 0.929)    // #EEEEED
    )
    static let textSecondary = Color(
        light: Color(red: 0.345, green: 0.345, blue: 0.337),
        dark:  Color(red: 0.635, green: 0.635, blue: 0.627)    // #A2A2A0
    )
    static let textMuted = Color(
        light: Color(red: 0.545, green: 0.545, blue: 0.537),
        dark:  Color(red: 0.435, green: 0.435, blue: 0.427)    // #6F6F6D
    )

    // MARK: - Semantic
    static let successGlow = Color(
        light: Color(red: 0.298, green: 0.620, blue: 0.384),
        dark:  Color(red: 0.427, green: 0.741, blue: 0.510)    // #6DBD82
    )
    static let warningGlow = Color(
        light: Color(red: 0.859, green: 0.553, blue: 0.196),
        dark:  Color(red: 0.976, green: 0.706, blue: 0.341)    // #F9B457
    )
    static let criticalGlow = Color(
        light: Color(red: 0.824, green: 0.314, blue: 0.282),
        dark:  Color(red: 0.906, green: 0.396, blue: 0.365)    // #E7655D
    )

    // MARK: - Legacy v4 aliases (kept so older views don't need rewrites)
    static var neonCyan: Color    { accent }
    static var brightCyan: Color  { accentBright }
    static var deepCyan: Color    { accentMuted }
    static var halRed: Color      { accent }
    static var halFlare: Color    { accentBright }
    static var halDeep: Color     { accentMuted }
    static var halBrass: Color    { accent }
    static var halWarning: Color  { warningGlow }

    // MARK: - Motion tokens (v1.4 Fase 2c — glass-refined spring unification)

    /// Unified spring curve for appear / disappear / state transitions.
    /// Apple's default animation feel — calm, doesn't overshoot. Use this
    /// instead of `.easeOut(duration: 0.1)` etc. so every view feels part of
    /// the same app.
    static let spring: Animation = .spring(response: 0.5, dampingFraction: 0.82)

    /// Tighter spring for cards / chips / small UI elements that should
    /// settle faster than full-screen transitions.
    static let springSnappy: Animation = .spring(response: 0.35, dampingFraction: 0.85)

    // MARK: - Typography tokens

    /// Rounded display face — used for the HUD header, mode name, Cockpit
    /// title. SF Pro Rounded reads as friendlier than SF Pro Text at large
    /// sizes, which suits the HUD's "quiet co-pilot" tone.
    static func display(size: CGFloat = 14, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: - Gradients

    /// Surface gradient used behind complex content. Dynamic so it re-evaluates
    /// when the appearance flips; static-let doesn't re-compute so it's wrapped
    /// in a computed property that always reads the current light/dark surfaces.
    static var surfaceGradient: LinearGradient {
        LinearGradient(colors: [surfaceBase, surfaceElevated],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Legacy alias (was deepSpaceGradient).
    static var deepSpaceGradient: LinearGradient { surfaceGradient }

    /// Subtle border glow when the HUD is active.
    static var borderGradient: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.35), hairline],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Used by the pulsing recording indicator dot.
    static var coreGradient: RadialGradient {
        RadialGradient(colors: [accentBright, accent, accent.opacity(0)],
                       center: .center, startRadius: 0, endRadius: 12)
    }

    /// Chat user-message bubble.
    static var userBubble: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.85), accentMuted.opacity(0.7)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Color init helper (light/dark)

extension Color {
    /// Build a dynamic colour that switches on the current `NSAppearance`.
    /// SwiftUI still doesn't ship a first-party Color(light:dark:) init on
    /// macOS, so we route through NSColor's dynamicProvider and bridge back.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return isDark ? NSColor(dark) : NSColor(light)
        })
    }
}
