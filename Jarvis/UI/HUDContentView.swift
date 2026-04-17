import SwiftUI

struct HUDContentView: View {
    let text: String
    let onClose: () -> Void
    var onSpeak: ((String) -> Void)?
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform.circle.fill").foregroundStyle(.accent)
                Text("Jarvis").font(.headline)
                Spacer()
                Button(action: { onSpeak?(text) }) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Read aloud")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            Divider()
            ScrollView {
                Text(text)
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(minWidth: 360, maxWidth: 360, minHeight: 100, maxHeight: 240)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
        }
    }
}
