import AppKit
import SwiftUI

struct MarkdownTextView: View {
    let text: String
    let foregroundColor: Color

    init(_ text: String, foregroundColor: Color = .primary) {
        self.text = text
        self.foregroundColor = foregroundColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block Types

    fileprivate struct Citation: Identifiable, Equatable {
        let id = UUID()
        let number: Int
        let title: String
        let url: URL
    }

    private enum Block {
        case text(String)
        case code(language: String, content: String)
        case citations([Citation])
    }

    // MARK: - Parser

    private func parseBlocks() -> [Block] {
        // First, lift the trailing **Kilder** / Sources section (if any) into
        // a structured citation block so it can render as compact chips
        // instead of a bulky numbered link list.
        let (body, citations) = Self.extractCitationFooter(text)

        var blocks: [Block] = []
        let lines = body.components(separatedBy: "\n")
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

        if !citations.isEmpty {
            blocks.append(.citations(citations))
        }

        return blocks
    }

    /// Split the tail "**Kilder**" / "Sources" section off the body and parse
    /// its numbered markdown-link list into structured `Citation`s. Returns
    /// the body text with the footer removed and the parsed citations. If no
    /// recognised section is found, returns the input unchanged with an
    /// empty array.
    fileprivate static func extractCitationFooter(_ input: String) -> (body: String, citations: [Citation]) {
        let headerMarkers = ["**Kilder**", "## Kilder", "### Kilder", "Kilder:", "**Sources**", "Sources:"]
        let lines = input.components(separatedBy: "\n")
        var headerIndex: Int?
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if headerMarkers.contains(where: { line.hasPrefix($0) }) {
                headerIndex = i
                break
            }
        }
        guard let headerIndex else { return (input, []) }

        // Everything before the header is body; everything after (up to a
        // blank-line break) are citation lines.
        let body = lines[..<headerIndex].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var citations: [Citation] = []
        // Regex: "1. [Title](url)" with optional whitespace, period allowed
        // after number, trailing content ignored.
        let pattern = #"^\s*(\d+)\.\s*\[([^\]]+)\]\(([^)]+)\)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        for raw in lines[(headerIndex + 1)...] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard
                let regex,
                let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                match.numberOfRanges >= 4,
                let numRange = Range(match.range(at: 1), in: line),
                let titleRange = Range(match.range(at: 2), in: line),
                let urlRange = Range(match.range(at: 3), in: line),
                let num = Int(line[numRange]),
                let url = URL(string: String(line[urlRange]))
            else { continue }
            citations.append(Citation(number: num, title: String(line[titleRange]), url: url))
        }
        return (body, citations)
    }

    // MARK: - Rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .text(let content):
            markdownText(content)
        case .code(let language, let content):
            codeBlockView(language: language, content: content)
        case .citations(let citations):
            CitationsView(citations: citations)
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

// MARK: - Citation chips (v1.3 compact source-footer UI)

/// Renders extracted source citations as a row of compact, clickable chips
/// instead of a bulky numbered list. Each chip shows a circled number + the
/// host (or a truncated title) + an external-link glyph. Chips wrap across
/// lines so 8+ sources don't force a horizontal scroll.
private struct CitationsView: View {
    let citations: [MarkdownTextView.Citation]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "link.circle.fill")
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.accent.opacity(0.85))
                Text("Kilder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("\(citations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(citations) { c in
                    CitationChip(citation: c)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Simple horizontal-flow layout that wraps rows when the proposed width
/// runs out. macOS 13+ Layout protocol; no third-party dep.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : x
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct CitationChip: View {
    let citation: MarkdownTextView.Citation
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Text("\(citation.number)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(JarvisTheme.accent.opacity(hovering ? 1.0 : 0.85)))

                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(hovering ? JarvisTheme.textPrimary : .secondary)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(hovering ? 0.9 : 0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(hovering ? 0.18 : 0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(JarvisTheme.accent.opacity(hovering ? 0.5 : 0.2), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(citation.url.absoluteString)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    /// Prefer the page title; fall back to the host if the title is long or
    /// generic. Capped at ~22 characters so chips stay compact.
    private var label: String {
        let title = citation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = citation.url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        let preferred = title.count > 0 && title.count <= 28 ? title : host
        return preferred.count > 28 ? String(preferred.prefix(27)) + "…" : preferred
    }

    private func open() {
        NSWorkspace.shared.open(citation.url)
    }
}
