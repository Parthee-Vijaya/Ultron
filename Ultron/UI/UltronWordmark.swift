import SwiftUI

/// Branded wordmark rendered above the chat greeting — the classic Stark
/// "circle with text cutting through" identity. v1.4 Fase 2c iteration:
/// two arc segments with gaps on the left and right sides, and the
/// wordmark centred so the text visually interrupts the ring.
///
/// Everything is pure SwiftUI + the system SF Compact font (best available
/// built-in match for the sci-fi-tech feel of the source design; a custom
/// Orbitron / Michroma face could come later if we want a closer match).
struct UltronWordmark: View {
    /// Font size of the wordmark letters. 21pt is the previous 17pt + 25%.
    /// Whole mark scales off this so a hero-sized placement is a one-liner.
    var fontSize: CGFloat = 21

    /// Breathing-pulse driver. On = dim + slightly smaller; off = bright +
    /// full size. 1.8s ease-in-out auto-reversed so the rhythm reads as a
    /// calm "it's listening" cue rather than a distracting beat.
    @State private var pulse: Bool = false

    var body: some View {
        Text("J.A.R.V.I.S")
            .font(.system(size: fontSize, weight: .bold))
            .kerning(fontSize * 0.14)
            .foregroundStyle(Color.white)
            .fixedSize(horizontal: true, vertical: true)
            .opacity(pulse ? 0.55 : 1.0)
            .scaleEffect(pulse ? 0.97 : 1.0)
            .animation(
                .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("J.A.R.V.I.S")
    }
}
