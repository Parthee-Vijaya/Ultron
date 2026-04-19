import SwiftUI

/// Chat message row — Claude-desktop inspired.
///
/// User messages: right-aligned, amber-tinted pill with max 80% width.
/// Assistant messages: full-width with no bubble, just a subtle icon gutter so
/// the reader's eye tracks who's speaking. This matches how Anthropic's
/// desktop app lays out its threads.
struct MessageBubble: View {
    let message: ChatMessage
    /// v1.1.5: optional retry callback rendered when `message.lastError` is
    /// set. Nil means retry is unavailable (legacy ChatView path).
    var onRetry: ((ChatMessage) -> Void)? = nil
    /// v1.4 (Fase 2b): when true, a pulsing ▌ caret renders below the
    /// rendered markdown so the user has an obvious "still typing…" cue.
    /// Only pass true for the single message currently being streamed by
    /// ChatSession (typically the trailing assistant message).
    var isStreaming: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 40)
                userBubble
            } else {
                assistantIcon
                assistantBody
                Spacer(minLength: 0)
            }
        }
    }

    private var userBubble: some View {
        MarkdownTextView(message.text, foregroundColor: .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(JarvisTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(JarvisTheme.accentBright.opacity(0.6), lineWidth: 0.75)
            )
    }

    private var assistantIcon: some View {
        Circle()
            .fill(JarvisTheme.accent)
            .frame(width: 22, height: 22)
            .overlay(
                Text("J")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Constants.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(JarvisTheme.textSecondary)
            MarkdownTextView(message.text, foregroundColor: JarvisTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isStreaming {
                StreamingCursor()
            }
            if message.lastError != nil, let onRetry {
                retryPill(onRetry)
            }
        }
    }

    private func retryPill(_ onRetry: @escaping (ChatMessage) -> Void) -> some View {
        Button { onRetry(message) } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                Text("Prøv igen")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(JarvisTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(JarvisTheme.surfaceElevated)
                    .overlay(Capsule().stroke(JarvisTheme.accent.opacity(0.5), lineWidth: 0.75))
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help("Gentag samme prompt")
    }
}

// MARK: - Streaming cursor (v1.4 Fase 2b.1)

/// Thin pulsing block caret rendered below an assistant message while it's
/// mid-stream. Uses a repeating opacity animation — no timers, no tasks;
/// SwiftUI drives the pulse and stops it for free when the parent removes
/// this view after streaming ends.
private struct StreamingCursor: View {
    @State private var dim = false

    var body: some View {
        Text("▌")
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundStyle(JarvisTheme.accent)
            .opacity(dim ? 0.25 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
            .accessibilityLabel("Jarvis skriver")
            .accessibilityHidden(false)
    }
}
