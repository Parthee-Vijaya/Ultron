import SwiftUI

/// Chat message row — Claude-desktop inspired.
///
/// User messages: right-aligned, amber-tinted pill with max 80% width.
/// Assistant messages: full-width with no bubble, just a subtle icon gutter so
/// the reader's eye tracks who's speaking. This matches how Anthropic's
/// desktop app lays out its threads.
struct MessageBubble: View {
    let message: ChatMessage

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
            Text("Jarvis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(JarvisTheme.textSecondary)
            MarkdownTextView(message.text, foregroundColor: JarvisTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
