import Foundation

/// One hit from a web-search fallback. Fed to Gemini as context so the model
/// doesn't have to rely on stale training-data facts.
struct SearchResult: Equatable, Sendable {
    let title: String
    let snippet: String
    let url: String

    /// Formatted block for prompt injection: `[idx] title` / url / snippet.
    func promptBlock(index: Int) -> String {
        var block = "[\(index)] \(title)\n    \(url)"
        if !snippet.isEmpty {
            block += "\n    \(snippet.replacingOccurrences(of: "\n", with: " "))"
        }
        return block
    }
}

/// Parallel multi-source live lookup. α.10 onward queries DuckDuckGo Instant
/// Answer, English Wikipedia AND Danish Wikipedia in parallel. Results are
/// deduped by URL and capped at `limit`. All sources are key-free.
actor WebSearchService {
    static let shared = WebSearchService()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    func search(query: String, limit: Int = 5) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let isDanish = Self.looksDanish(trimmed)

        // Run all lookups in parallel. If the user's query is Danish we prioritise
        // Danish Wikipedia and only fall back to EN for coverage.
        async let ddgResults = fetchDDGInstantAnswer(query: trimmed)
        async let enWiki = fetchWikipediaSummaries(query: trimmed, lang: "en", limit: 3)
        async let daWiki = fetchWikipediaSummaries(query: trimmed, lang: "da", limit: 3)

        let (ddg, en, da) = await (ddgResults, enWiki, daWiki)

        // Prefer da results first when user is Danish, otherwise EN first.
        var combined = isDanish
            ? da + ddg + en
            : en + ddg + da

        // Deduplicate by URL
        var seen = Set<String>()
        combined = combined.filter { result in
            guard !result.url.isEmpty else { return true }
            let host = URL(string: result.url)?.absoluteString ?? result.url
            if seen.contains(host) { return false }
            seen.insert(host)
            return true
        }

        if combined.count > limit {
            combined = Array(combined.prefix(limit))
        }

        if combined.isEmpty {
            LoggingService.shared.log("WebSearch: no results for '\(trimmed)'", level: .warning)
        } else {
            LoggingService.shared.log("WebSearch: \(combined.count) results (\(ddg.count) DDG + \(en.count) enWiki + \(da.count) daWiki, isDanish=\(isDanish)) for '\(trimmed.prefix(60))'")
        }
        return combined
    }

    // MARK: - DuckDuckGo Instant Answer

    private func fetchDDGInstantAnswer(query: String) async -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1") else {
            return []
        }
        guard let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [SearchResult] = []

        if let abstract = root["AbstractText"] as? String, !abstract.isEmpty {
            let source = (root["AbstractSource"] as? String) ?? "DuckDuckGo"
            let sourceURL = (root["AbstractURL"] as? String) ?? "https://duckduckgo.com/?q=\(encoded)"
            results.append(SearchResult(title: source, snippet: abstract, url: sourceURL))
        }

        if let answer = root["Answer"] as? String, !answer.isEmpty {
            results.append(SearchResult(
                title: "DuckDuckGo direct answer",
                snippet: answer,
                url: "https://duckduckgo.com/?q=\(encoded)"
            ))
        }

        if let related = root["RelatedTopics"] as? [[String: Any]] {
            for topic in related.prefix(2) {
                guard let text = topic["Text"] as? String, !text.isEmpty else { continue }
                let firstURL = topic["FirstURL"] as? String ?? ""
                let title = text.components(separatedBy: " - ").first ?? text
                let snippet = text.count > title.count
                    ? String(text.dropFirst(title.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
                    : text
                results.append(SearchResult(
                    title: title,
                    snippet: snippet.isEmpty ? text : snippet,
                    url: firstURL
                ))
            }
        }
        return results
    }

    // MARK: - Wikipedia (language-specific)

    /// Uses Wikipedia's **fulltext search** (`action=query&list=search`) — returns
    /// real search results with snippets, not just title matches. The fulltext
    /// index covers article body content, so questions like "when did ukraine war
    /// start" hit "Russo-Ukrainian war (2022–present)" with a matching snippet
    /// even though no Wikipedia article is literally titled that.
    ///
    /// Each hit's page summary is then fetched in parallel via the REST API so
    /// we have the opening paragraph as clean prose for the model.
    private func fetchWikipediaSummaries(query: String, lang: String, limit: Int) async -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://\(lang).wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encoded)&srlimit=\(limit)&srprop=snippet&format=json") else {
            return []
        }
        guard let (data, _) = try? await session.data(from: searchURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let hits = query["search"] as? [[String: Any]] else {
            return []
        }

        var results: [SearchResult] = []
        await withTaskGroup(of: SearchResult?.self) { group in
            for hit in hits.prefix(limit) {
                guard let title = hit["title"] as? String else { continue }
                let rawSnippet = hit["snippet"] as? String ?? ""
                // Strip Wikipedia's <span class="searchmatch"> markup from snippets.
                let snippet = rawSnippet
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                group.addTask { [weak self] in
                    await self?.fetchWikiSummary(title: title, fallbackSnippet: snippet, lang: lang)
                }
            }
            for await result in group {
                if let result { results.append(result) }
            }
        }
        return results
    }

    private func fetchWikiSummary(title: String, fallbackSnippet: String, lang: String) async -> SearchResult? {
        let normalised = title.replacingOccurrences(of: " ", with: "_")
        let pageURL = "https://\(lang).wikipedia.org/wiki/\(normalised)"

        guard let encoded = normalised.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            // Fall back to raw snippet if even URL encoding fails.
            return fallbackSnippet.isEmpty ? nil :
                SearchResult(title: title, snippet: fallbackSnippet, url: pageURL)
        }

        // Try REST summary for the nice extract; fall back to the fulltext
        // snippet if the summary endpoint 404s (redirects, disambigs, etc).
        if let (data, _) = try? await session.data(from: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let extract = root["extract"] as? String, !extract.isEmpty {
            return SearchResult(
                title: (root["title"] as? String) ?? title,
                snippet: extract,
                url: pageURL
            )
        }
        guard !fallbackSnippet.isEmpty else { return nil }
        return SearchResult(title: title, snippet: fallbackSnippet, url: pageURL)
    }

    // MARK: - Language detection

    /// Fast heuristic for "is this Danish" — looks for unique Danish letters
    /// (æ/ø/å) OR a common Danish stop-word. Good enough for prioritising
    /// Danish Wikipedia results; false positives don't hurt since EN is still
    /// queried in parallel.
    static func looksDanish(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("æ") || lower.contains("ø") || lower.contains("å") {
            return true
        }
        let stopWords = [
            " hvem ", " hvad ", " hvor ", " hvorfor ", " hvornår ",
            " og ", " eller ", " ikke ", " dansk ", " denmark ", " danmark ",
            " kongen ", " regering ", " folketinget "
        ]
        let padded = " \(lower) "
        return stopWords.contains { padded.contains($0) }
    }
}
