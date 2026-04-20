import SwiftUI

/// Rolling oscilloscope strip rendered on a cyan glow. Reads from `WaveformBuffer`
/// and draws a mirrored waveform (top half above center, bottom half below) so the
/// shape stays symmetric even when the user's voice clips only positive peaks.
struct WaveformScope: View {
    let buffer: WaveformBuffer
    var height: CGFloat = 40

    var body: some View {
        Canvas { context, size in
            let samples = buffer.samples
            guard samples.count > 1 else { return }

            let midY = size.height / 2
            let stepX = size.width / CGFloat(samples.count - 1)
            let amplitude = size.height / 2 - 2

            var top = Path()
            var bottom = Path()

            for (i, value) in samples.enumerated() {
                let x = CGFloat(i) * stepX
                let mag = abs(CGFloat(value)) * amplitude
                let yUp = midY - mag
                let yDown = midY + mag
                if i == 0 {
                    top.move(to: CGPoint(x: x, y: yUp))
                    bottom.move(to: CGPoint(x: x, y: yDown))
                } else {
                    top.addLine(to: CGPoint(x: x, y: yUp))
                    bottom.addLine(to: CGPoint(x: x, y: yDown))
                }
            }

            // Closed fill — a bellied envelope from top to bottom.
            var envelope = top
            envelope.addLine(to: CGPoint(x: size.width, y: midY))
            envelope.addPath(bottom.reversed())
            envelope.closeSubpath()

            context.fill(
                envelope,
                with: .linearGradient(
                    Gradient(colors: [
                        UltronTheme.accentBright.opacity(0.55),
                        UltronTheme.accent.opacity(0.28),
                        UltronTheme.accentMuted.opacity(0.1)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            // Crisp amber edge line on top + bottom for definition.
            context.stroke(top, with: .color(UltronTheme.accentBright), lineWidth: 1)
            context.stroke(bottom, with: .color(UltronTheme.accent.opacity(0.75)), lineWidth: 1)

            // Center reference — very dim neutral so it doesn't steal focus.
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: midY))
            centerLine.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(centerLine, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)
        }
        .frame(height: height)
    }
}

extension Path {
    fileprivate func reversed() -> Path {
        // SwiftUI's Path doesn't expose reverse(); build a new one by walking the elements.
        var points: [CGPoint] = []
        self.forEach { element in
            switch element {
            case .move(to: let p):   points.append(p)
            case .line(to: let p):   points.append(p)
            default: break
            }
        }
        var reversed = Path()
        for (i, p) in points.reversed().enumerated() {
            if i == 0 { reversed.move(to: p) } else { reversed.addLine(to: p) }
        }
        return reversed
    }
}
