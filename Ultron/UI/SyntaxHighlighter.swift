import SwiftUI

/// Pure-Swift lightweight syntax highlighter for the 80 % case (swift / js /
/// ts / py / sh / rust / go / json / yaml / markdown). No external deps, just
/// regex tokenisation emitting an `AttributedString` with per-token colours.
///
/// Intentionally not a "real" lexer. It misses edge cases (triple-quoted
/// strings, string interpolation boundaries). The goal is a readable chat
/// bubble, not a compiler pipeline.
enum SyntaxHighlighter {
    static func highlight(_ source: String, language: String) -> AttributedString {
        let lang = language.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spec = Self.spec(for: lang) else {
            // Unknown language → plain monospace, no colour.
            return plain(source)
        }

        var attributed = AttributedString(source)
        attributed.font = .system(.caption, design: .monospaced)
        attributed.foregroundColor = UltronTheme.textPrimary

        // Apply in order: comments last (they override everything inside them),
        // strings second-to-last, then keywords + numbers + types.
        apply(regex: spec.numberRegex, to: &attributed, in: source, color: Colors.number)
        apply(regex: spec.typeRegex, to: &attributed, in: source, color: Colors.type)
        apply(words: spec.keywords, to: &attributed, in: source, color: Colors.keyword)
        apply(regex: spec.stringRegex, to: &attributed, in: source, color: Colors.string)
        apply(regex: spec.commentRegex, to: &attributed, in: source, color: Colors.comment)

        return attributed
    }

    private static func plain(_ source: String) -> AttributedString {
        var attributed = AttributedString(source)
        attributed.font = .system(.caption, design: .monospaced)
        attributed.foregroundColor = UltronTheme.textPrimary
        return attributed
    }

    // MARK: - Token colours

    private enum Colors {
        static let keyword: Color = Color(red: 0.78, green: 0.52, blue: 0.97)  // violet
        static let string:  Color = Color(red: 0.60, green: 0.82, blue: 0.54)  // green
        static let comment: Color = UltronTheme.textMuted
        static let number:  Color = Color(red: 0.95, green: 0.67, blue: 0.35)  // amber
        static let type:    Color = UltronTheme.accent                          // Ultron cyan/amber accent
    }

    // MARK: - Regex application

    private static func apply(
        regex: NSRegularExpression?,
        to attributed: inout AttributedString,
        in source: String,
        color: Color
    ) {
        guard let regex else { return }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        regex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let match, let swiftRange = Range(match.range, in: source) else { return }
            if let attributedRange = Range(swiftRange, in: attributed) {
                attributed[attributedRange].foregroundColor = color
            }
        }
    }

    private static func apply(
        words: [String],
        to attributed: inout AttributedString,
        in source: String,
        color: Color
    ) {
        guard !words.isEmpty else { return }
        let escaped = words.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "\\b(" + escaped.joined(separator: "|") + ")\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        apply(regex: regex, to: &attributed, in: source, color: color)
    }

    // MARK: - Per-language spec

    private struct LanguageSpec {
        let keywords: [String]
        let stringRegex: NSRegularExpression?
        let commentRegex: NSRegularExpression?
        let numberRegex: NSRegularExpression?
        let typeRegex: NSRegularExpression?
    }

    private static func spec(for language: String) -> LanguageSpec? {
        switch language {
        case "swift":
            return LanguageSpec(
                keywords: swiftKeywords,
                stringRegex: try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#),
                commentRegex: try? NSRegularExpression(pattern: #"(//[^\n]*)|(/\*[\s\S]*?\*/)"#),
                numberRegex: try? NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#),
                typeRegex: try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)
            )
        case "js", "javascript", "ts", "typescript":
            return LanguageSpec(
                keywords: jsKeywords,
                stringRegex: try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#),
                commentRegex: try? NSRegularExpression(pattern: #"(//[^\n]*)|(/\*[\s\S]*?\*/)"#),
                numberRegex: try? NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#),
                typeRegex: try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)
            )
        case "py", "python":
            return LanguageSpec(
                keywords: pythonKeywords,
                stringRegex: try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#),
                commentRegex: try? NSRegularExpression(pattern: #"#[^\n]*"#),
                numberRegex: try? NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#),
                typeRegex: nil
            )
        case "sh", "bash", "zsh", "shell":
            return LanguageSpec(
                keywords: shellKeywords,
                stringRegex: try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'[^']*'"#),
                commentRegex: try? NSRegularExpression(pattern: #"#[^\n]*"#),
                numberRegex: try? NSRegularExpression(pattern: #"\b\d+\b"#),
                typeRegex: nil
            )
        case "rust", "rs":
            return LanguageSpec(
                keywords: rustKeywords,
                stringRegex: try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#),
                commentRegex: try? NSRegularExpression(pattern: #"(//[^\n]*)|(/\*[\s\S]*?\*/)"#),
                numberRegex: try? NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?(?:[iuf]\d+)?\b"#),
                typeRegex: try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)
            )
        case "go", "golang":
            return LanguageSpec(
                keywords: goKeywords,
                stringRegex: try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|`[^`]*`"#),
                commentRegex: try? NSRegularExpression(pattern: #"(//[^\n]*)|(/\*[\s\S]*?\*/)"#),
                numberRegex: try? NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#),
                typeRegex: try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)
            )
        case "json":
            return LanguageSpec(
                keywords: ["true", "false", "null"],
                stringRegex: try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#),
                commentRegex: nil,
                numberRegex: try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#),
                typeRegex: nil
            )
        case "yaml", "yml":
            return LanguageSpec(
                keywords: ["true", "false", "null", "yes", "no"],
                stringRegex: try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'[^']*'"#),
                commentRegex: try? NSRegularExpression(pattern: #"#[^\n]*"#),
                numberRegex: try? NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#),
                typeRegex: try? NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*(?=:)"#, options: [.anchorsMatchLines])
            )
        case "md", "markdown":
            return LanguageSpec(
                keywords: [],
                stringRegex: try? NSRegularExpression(pattern: #"\[[^\]]+\]\([^\)]+\)"#), // links
                commentRegex: try? NSRegularExpression(pattern: #"^#{1,6} [^\n]*"#, options: [.anchorsMatchLines]), // headings
                numberRegex: nil,
                typeRegex: try? NSRegularExpression(pattern: #"(\*\*[^*]+\*\*)|(__[^_]+__)"#)
            )
        default:
            return nil
        }
    }

    // MARK: - Keyword lists

    private static let swiftKeywords: [String] = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
        "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "init",
        "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator",
        "override", "private", "protocol", "public", "repeat", "return", "self", "Self", "set", "some",
        "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
        "var", "weak", "where", "while", "willSet", "didSet"
    ]

    private static let jsKeywords: [String] = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally",
        "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let",
        "new", "null", "of", "package", "private", "protected", "public", "return", "super", "switch",
        "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with",
        "yield", "any", "boolean", "number", "string", "never", "unknown", "readonly"
    ]

    private static let pythonKeywords: [String] = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
        "with", "yield", "match", "case", "self"
    ]

    private static let shellKeywords: [String] = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done",
        "function", "return", "in", "export", "source", "local", "readonly", "echo", "printf", "read",
        "cd", "pwd", "ls", "cp", "mv", "rm", "mkdir", "rmdir", "touch", "cat", "grep", "sed", "awk",
        "find", "true", "false"
    ]

    private static let rustKeywords: [String] = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
        "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
        "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type",
        "unsafe", "use", "where", "while"
    ]

    private static let goKeywords: [String] = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return",
        "select", "struct", "switch", "type", "var", "true", "false", "nil", "iota"
    ]
}
