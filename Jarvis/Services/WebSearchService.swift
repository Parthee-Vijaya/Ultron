import Foundation

/// One hit from a web search. The Gemini prompt reducer reads these and
/// formats them into context lines.
struct SearchResult: Equatable, Sendable {
    let title: String
    let snippet: String
    let url: String

    /// Plain-text line suitable for prepending to a Gemini prompt.
    var promptLine: String {
        "• \(title) — \(snippet) (\(url))"
    }
}

/// Front-ends DuckDuckGo's public HTML endpoint — no API key, no rate limit
/// for reasonable use, privacy-friendly. Returns the top N result rows
/// extracted from the markup so we can prepend them as context to Gemini
/// when grounding needs to be reliable.
actor WebSearchService {
    static let shared = WebSearchService()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        // DDG sometimes responds slower than generativelanguage — keep the
        // resource timeout generous so we don't lose results over flaky wifi.
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func search(query: String, limit: Int = 3) async -> [SearchResult] {
        guard let encoded = query.trimmingCharacters(in: .whitespaces)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              !encoded.isEmpty,
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605 Jarvis/5.0",
                         forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                LoggingService.shared.log("WebSearch: non-200 or non-UTF8 from DDG", level: .warning)
                return []
            }
            return parseResults(html: html, limit: limit)
        } catch {
            LoggingService.shared.log("WebSearch failed: \(error.localizedDescription)", level: .warning)
            return []
        }
    }

    // MARK: - Parsing

    /// Minimal regex-based scraper. DDG's HTML result blocks consistently look like:
    ///
    ///     <a class="result__a" href="/l/?uddg=…">TITLE</a>
    ///     …
    ///     <a class="result__snippet" …>SNIPPET</a>
    ///
    /// where the `href` for titles is a DDG redirect we decode back to the real URL.
    private func parseResults(html: String, limit: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        var cursor = html.startIndex

        while results.count < limit, cursor < html.endIndex {
            guard let titleStart = html.range(of: "class=\"result__a\"", range: cursor..<html.endIndex),
                  let hrefRange = html.range(of: "href=\"", range: titleStart.upperBound..<html.endIndex),
                  let hrefEnd = html.range(of: "\"", range: hrefRange.upperBound..<html.endIndex) else {
                break
            }
            let rawHref = String(html[hrefRange.upperBound..<hrefEnd.lowerBound])
            let resolvedURL = decodeRedirect(rawHref)

            guard let titleBodyStart = html.range(of: ">", range: hrefEnd.upperBound..<html.endIndex),
                  let titleBodyEnd = html.range(of: "</a>", range: titleBodyStart.upperBound..<html.endIndex) else {
                cursor = hrefEnd.upperBound
                continue
            }
            let title = String(html[titleBodyStart.upperBound..<titleBodyEnd.lowerBound])
                .stripHTMLTags()
                .decodedHTMLEntities()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Next snippet — search forward from the title close.
            var snippet = ""
            if let snippetStart = html.range(of: "class=\"result__snippet\"", range: titleBodyEnd.upperBound..<html.endIndex),
               let snippetBodyStart = html.range(of: ">", range: snippetStart.upperBound..<html.endIndex),
               let snippetBodyEnd = html.range(of: "</a>", range: snippetBodyStart.upperBound..<html.endIndex) {
                snippet = String(html[snippetBodyStart.upperBound..<snippetBodyEnd.lowerBound])
                    .stripHTMLTags()
                    .decodedHTMLEntities()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cursor = snippetBodyEnd.upperBound
            } else {
                cursor = titleBodyEnd.upperBound
            }

            if !title.isEmpty {
                results.append(SearchResult(title: title, snippet: snippet, url: resolvedURL))
            }
        }
        return results
    }

    /// DDG wraps result links in `/l/?uddg=<url-encoded>&rut=…`. Pull out the real URL.
    private func decodeRedirect(_ raw: String) -> String {
        guard raw.contains("uddg=") else { return raw }
        let cleaned = raw.hasPrefix("//") ? "https:" + raw : raw
        if let url = URL(string: cleaned),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return uddg
        }
        return raw
    }
}

// MARK: - String helpers (HTML)

extension String {
    fileprivate func stripHTMLTags() -> String {
        self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    fileprivate func decodedHTMLEntities() -> String {
        self
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
