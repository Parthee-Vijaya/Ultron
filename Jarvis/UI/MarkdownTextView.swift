import SwiftUI

struct MarkdownTextView: View {
    let text: String
    let foregroundColor: Color

    init(_ text: String, foregroundColor: Color = .primary) {
        self.text = text
        self.foregroundColor = foregroundColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block Types

    private enum Block {
        case text(String)
        case code(language: String, content: String)
    }

    // MARK: - Parser

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLang = ""
        var codeLines: [String] = []
        var textLines: [String] = []

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block
                    blocks.append(.code(language: codeLang, content: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    codeLang = ""
                    inCodeBlock = false
                } else {
                    // Start of code block — flush text
                    if !textLines.isEmpty {
                        blocks.append(.text(textLines.joined(separator: "\n")))
                        textLines.removeAll()
                    }
                    codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                codeLines.append(line)
            } else {
                textLines.append(line)
            }
        }

        // Flush remaining
        if inCodeBlock {
            // Unclosed code block
            blocks.append(.code(language: codeLang, content: codeLines.joined(separator: "\n")))
        }
        if !textLines.isEmpty {
            blocks.append(.text(textLines.joined(separator: "\n")))
        }

        return blocks
    }

    // MARK: - Rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .text(let content):
            markdownText(content)
        case .code(let language, let content):
            codeBlockView(language: language, content: content)
        }
    }

    private func markdownText(_ content: String) -> some View {
        Group {
            if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
                    .font(.body)
                    .foregroundStyle(foregroundColor)
                    .textSelection(.enabled)
            } else {
                Text(content)
                    .font(.body)
                    .foregroundStyle(foregroundColor)
                    .textSelection(.enabled)
            }
        }
    }

    private func codeBlockView(language: String, content: String) -> some View {
        CodeBlockView(language: language, content: content)
    }
}

/// v1.1.6: extracted so the copy button can track per-block "Copied!" state
/// without the parent MarkdownTextView having to hold a dictionary.
private struct CodeBlockView: View {
    let language: String
    let content: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy")
                    }
                    .font(.caption)
                    .foregroundStyle(copied ? JarvisTheme.accent : .secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // Code content — syntax-highlighted for the common languages,
            // plain monospace for unknown ones. Raw source still goes through
            // the Copy button above unchanged.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(content, language: language))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        // Clear the visual after 1.5 s — short enough to not get stuck, long
        // enough for the user to confirm the copy happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) { copied = false }
        }
    }
}
