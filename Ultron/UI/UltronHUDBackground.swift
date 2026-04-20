import SwiftUI

/// HUD backdrop — v1.4 Fase 2c glass-refined direction.
///
/// Layer stack:
///   1. surfaceBase (dynamic light/dark base colour for contrast fallback)
///   2. .regularMaterial (macOS vibrancy — gives the HUD its "glass" feel)
///   3. Rounded clip + hairline stroke (0.5pt — just enough to separate from
///      the desktop without looking drawn)
///   4. Native drop shadow (system shadow-style matches Apple first-party
///      floating panels like Spotlight and the Now Playing widget)
///
/// v1.3 and earlier used `UltronTheme.surfaceBase` flat + a custom 20pt/8y
/// shadow with 0.45 alpha — that read as heavy on the light-mode variant and
/// didn't blend with the user's wallpaper. Materials + native drop shadow
/// fixes both.
struct UltronHUDBackground: ViewModifier {
    var cornerRadius: CGFloat = Constants.HUD.cornerRadius
    /// Retained for API compatibility — reticle corners are gone in α.5.
    var showReticle: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                // Material needs an opaque-ish base below it or the HUD reads
                // too transparent on a busy desktop. 0.6 opacity gives enough
                // substance while still letting vibrancy breathe.
                UltronTheme.surfaceBase.opacity(0.6),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(UltronTheme.hairline, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 18, y: 6)
    }
}

extension View {
    func ultronHUDBackground(cornerRadius: CGFloat = Constants.HUD.cornerRadius, showReticle: Bool = false) -> some View {
        modifier(UltronHUDBackground(cornerRadius: cornerRadius, showReticle: showReticle))
    }

    /// v1.4 Fase 2c unified shell: chat-flavoured backdrop — dark navy
    /// gradient on top of the HUD material. Shared by the chat window, the
    /// Q&A HUD result surface, the Cockpit panel and the Briefing panel so
    /// all four panels read as the same family.
    func ultronChatBackdrop(cornerRadius: CGFloat = Constants.HUD.cornerRadius) -> some View {
        modifier(UltronChatBackdrop(cornerRadius: cornerRadius))
    }
}

/// Chat-style panel backdrop. Layers (bottom → top):
///   1. Deep-black → navy LinearGradient (matches `ChatView.chatBackdropGradient`)
///   2. `.regularMaterial` at low opacity for light-mode readability
///   3. Rounded clip + hairline stroke
///   4. Soft native drop shadow
struct UltronChatBackdrop: ViewModifier {
    var cornerRadius: CGFloat = Constants.HUD.cornerRadius

    func body(content: Content) -> some View {
        content
            .background(Self.gradient, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(.regularMaterial.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(UltronTheme.hairline, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 20, y: 8)
    }

    /// Shared gradient — promoted from ChatView so Q&A, Cockpit and Briefing
    /// can reuse the same stops. Near-black top fading to a warm navy at the
    /// bottom; reads "at night" rather than flat neutral.
    static let gradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.04, green: 0.04, blue: 0.07), location: 0.0),
            .init(color: Color(red: 0.05, green: 0.07, blue: 0.14), location: 0.55),
            .init(color: Color(red: 0.05, green: 0.10, blue: 0.22), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}
