import AppKit
import Foundation
import PDFKit

/// Reads text content from a URL for the summarize flow. Dispatches on extension:
///   • txt/md/swift/py/etc. → UTF-8 file read
///   • pdf                  → PDFKit text extraction
///   • docx/rtf/odt         → `textutil` shell-out (built-in on macOS)
struct DocumentReader {
    struct ExtractedDocument {
        let fileName: String
        let fileExtension: String
        let bytesOnDisk: Int
        let text: String
        let wasTruncated: Bool
    }

    /// Hard cap. Gemini 2.5 Flash takes up to 1M tokens but cost scales; 300k chars is
    /// ~75k tokens which covers a ~500-page book without burning money.
    static let maxCharacters = 300_000

    /// File-system extensions we know how to read. Used by the NSOpenPanel filter.
    static let supportedExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "log",
        "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "c", "cpp", "h", "hpp", "java", "cs", "php", "sh", "bash", "zsh",
        "json", "yaml", "yml", "toml", "xml", "csv", "tsv",
        "html", "htm", "css", "scss",
        "pdf",
        "docx", "odt", "pages"
    ]

    enum ReaderError: LocalizedError {
        case unsupportedType(String)
        case emptyContent
        case readFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext): return "Ultron kan ikke læse .\(ext)-filer endnu."
            case .emptyContent:             return "Dokumentet var tomt eller indeholdt ingen læselig tekst."
            case .readFailed(let error):    return "Kunne ikke læse filen: \(error.localizedDescription)"
            }
        }
    }

    func read(url: URL) throws -> ExtractedDocument {
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attrs[.size] as? Int) ?? 0

        let raw: String
        switch ext {
        case "pdf":
            raw = try extractPDF(url: url)
        case "docx", "odt", "pages":
            raw = try extractViaTextUtil(url: url)
        case "rtf":
            raw = try extractRTF(url: url)
        default:
            if Self.supportedExtensions.contains(ext) {
                raw = try extractPlainText(url: url)
            } else {
                throw ReaderError.unsupportedType(ext.isEmpty ? "ukendt" : ext)
            }
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReaderError.emptyContent }

        let (text, truncated) = truncate(trimmed, max: Self.maxCharacters)
        return ExtractedDocument(
            fileName: fileName,
            fileExtension: ext,
            bytesOnDisk: bytes,
            text: text,
            wasTruncated: truncated
        )
    }

    // MARK: - Extractors

    private func extractPlainText(url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Some logs/files are not UTF-8; try ISO Latin as a common fallback.
            if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
                return content
            }
            throw ReaderError.readFailed(underlying: error)
        }
    }

    private func extractPDF(url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ReaderError.readFailed(underlying: NSError(domain: "PDFKit", code: 1))
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let text = page.string {
                pages.append(text)
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private func extractRTF(url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url)
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            throw ReaderError.readFailed(underlying: error)
        }
    }

    /// textutil is a built-in macOS tool that reads .docx/.odt/.pages and emits plain text.
    /// Using it avoids bundling a DOCX XML parser.
    private func extractViaTextUtil(url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw ReaderError.readFailed(underlying: error)
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            throw ReaderError.readFailed(underlying: NSError(
                domain: "textutil", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "textutil exited with \(process.terminationStatus)"]
            ))
        }
        return text
    }

    private func truncate(_ text: String, max: Int) -> (String, Bool) {
        guard text.count > max else { return (text, false) }
        let endIndex = text.index(text.startIndex, offsetBy: max)
        return (String(text[..<endIndex]), true)
    }
}

// MARK: - Open-panel helper

enum DocumentPicker {
    /// Present an NSOpenPanel scoped to supported file types. Main-actor-only.
    @MainActor
    static func pickDocument() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Vælg et dokument"
        panel.prompt = "Opsummer"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []  // rely on extension filter below for compatibility
        panel.allowsOtherFileTypes = false
        panel.message = "Ultron understøtter .pdf, .docx, .txt, .md og de fleste kildetekst-formater."

        let response = panel.runModal()
        guard response == .OK,
              let url = panel.url else { return nil }
        let ext = url.pathExtension.lowercased()
        guard DocumentReader.supportedExtensions.contains(ext) else {
            // Show a friendly complaint rather than silently doing nothing.
            let alert = NSAlert()
            alert.messageText = "Filtypen .\(ext) understøttes ikke endnu"
            alert.informativeText = "Prøv en .pdf, .docx, .txt, .md eller anden tekstbaseret fil."
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
        return url
    }
}
