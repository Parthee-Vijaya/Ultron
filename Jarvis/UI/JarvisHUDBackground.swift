import SwiftUI

/// Claude-desktop-inspired HUD backdrop. v5.0.0-alpha.5 replaced the
/// gradient + neon-glow stack from v4 with a flat dark-neutral surface and a
/// single hairline border, matching Anthropic's desktop app aesthetic.
struct JarvisHUDBackground: ViewModifier {
    var cornerRadius: CGFloat = Constants.HUD.cornerRadius
    /// Retained for API compatibility — reticle corners are gone in α.5.
    var showReticle: Bool = false

    func body(content: Content) -> some View {
        content
            .background(JarvisTheme.surfaceBase)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(JarvisTheme.hairline, lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
    }
}

extension View {
    func jarvisHUDBackground(cornerRadius: CGFloat = Constants.HUD.cornerRadius, showReticle: Bool = false) -> some View {
        modifier(JarvisHUDBackground(cornerRadius: cornerRadius, showReticle: showReticle))
    }
}
