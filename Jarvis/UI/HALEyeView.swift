import SwiftUI

/// Compact recording indicator: small amber dot that breathes (idle) or
/// pulses sharply with voice RMS. Intentionally minimal — the big visual
/// emphasis lives in the waveform strip below it, matching Claude desktop's
/// restrained aesthetic. (Name kept as `HALEyeView` so nothing calling this
/// has to change; HAL heritage has been dropped in α.5.)
struct HALEyeView: View {
    /// 0...1 fraction of `Constants.maxRecordingDuration` elapsed — drives the
    /// thin progress ring around the outside.
    var progress: Double = 0
    /// Overall diameter of the assembly.
    var size: CGFloat = 28
    /// Audio level source — nil = idle breathing only.
    var levelMonitor: AudioLevelMonitor? = nil

    @State private var idlePulse: Bool = false

    private var intensity: Double {
        if let monitor = levelMonitor {
            return (monitor.level * 20).rounded() / 20
        }
        return idlePulse ? 0.65 : 0.0
    }

    var body: some View {
        ZStack {
            // Thin progress ring
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(JarvisTheme.accent.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.4), value: progress)

            // Subtle halo scales with intensity
            Circle()
                .fill(JarvisTheme.accent.opacity(0.25 + intensity * 0.35))
                .frame(width: size * 0.7, height: size * 0.7)
                .blur(radius: 3 + CGFloat(intensity) * 4)

            // Core dot — amber, scales with voice
            Circle()
                .fill(JarvisTheme.accentBright)
                .frame(
                    width: size * (0.42 + CGFloat(intensity) * 0.18),
                    height: size * (0.42 + CGFloat(intensity) * 0.18)
                )
                .shadow(color: JarvisTheme.accent.opacity(0.75),
                        radius: 2 + CGFloat(intensity) * 6)
                .animation(.easeOut(duration: 0.1), value: intensity)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                idlePulse = true
            }
        }
    }
}
