import Foundation

/// One hit from a web-search fallback. Fed to Gemini as context so the model
/// doesn't have to rely on stale training-data facts.
struct SearchResult: Equatable, Sendable {
    let title: String
    let snippet: String
    let url: String

    var promptLine: String {
        "• \(title) — \(snippet) (\(url))"
    }
}

/// Fetches live reference material for factual questions. v5.0.0-alpha.7
/// switched away from DDG's HTML endpoint after they started returning a
/// bot-detection "anomaly modal" to our scraper.
///
/// New strategy:
///   1. **DuckDuckGo Instant Answer JSON API** (`api.duckduckgo.com`) — no
///      captcha, returns an Abstract + Related Topics when the query has an
///      encyclopedic answer. Works for names, places, definitions.
///   2. **Wikipedia OpenSearch + Summary** — fallback when DDG has no
///      abstract. Guarantees at least one grounded result for anything that
///      has a Wikipedia page.
///
/// Both endpoints are public, key-free, rate-limit-friendly for personal use.
actor WebSearchService {
    static let shared = WebSearchService()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    func search(query: String, limit: Int = 3) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Run DDG + Wikipedia in parallel — whichever has data wins / they stack.
        async let ddgResults = fetchDDGInstantAnswer(query: trimmed)
        async let wikiResults = fetchWikipediaSummaries(query: trimmed, limit: limit)

        let (ddg, wiki) = await (ddgResults, wikiResults)
        var combined = ddg + wiki
        if combined.count > limit {
            combined = Array(combined.prefix(limit))
        }

        if combined.isEmpty {
            LoggingService.shared.log("WebSearch: no results for '\(trimmed)'", level: .warning)
        } else {
            LoggingService.shared.log("WebSearch: \(combined.count) results (\(ddg.count) DDG + \(wiki.count) Wiki) for '\(trimmed.prefix(60))'")
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

        // Abstract — typically the top-billed instant answer.
        if let abstract = root["AbstractText"] as? String, !abstract.isEmpty {
            let source = (root["AbstractSource"] as? String) ?? "DuckDuckGo"
            let sourceURL = (root["AbstractURL"] as? String) ?? "https://duckduckgo.com/?q=\(encoded)"
            results.append(SearchResult(
                title: source,
                snippet: abstract,
                url: sourceURL
            ))
        }

        // Direct answer (e.g., calculations, definitions)
        if let answer = root["Answer"] as? String, !answer.isEmpty {
            results.append(SearchResult(
                title: "Answer",
                snippet: answer,
                url: "https://duckduckgo.com/?q=\(encoded)"
            ))
        }

        // First 2 related topics for breadth
        if let related = root["RelatedTopics"] as? [[String: Any]] {
            for topic in related.prefix(2) {
                guard let text = topic["Text"] as? String, !text.isEmpty else { continue }
                let firstURL = topic["FirstURL"] as? String ?? ""
                // Related-topic titles are typically the first few words
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

    // MARK: - Wikipedia

    private func fetchWikipediaSummaries(query: String, limit: Int) async -> [SearchResult] {
        // 1) opensearch → top matching titles
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let openURL = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(encoded)&limit=\(limit)&format=json") else {
            return []
        }
        guard let (data, _) = try? await session.data(from: openURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 4,
              let titles = root[1] as? [String],
              let urls = root[3] as? [String] else {
            return []
        }

        var results: [SearchResult] = []
        // 2) for each title, fetch its summary in parallel
        await withTaskGroup(of: SearchResult?.self) { group in
            for (index, title) in titles.enumerated() where index < limit {
                let pageURL = (index < urls.count) ? urls[index] : ""
                group.addTask { [weak self] in
                    await self?.fetchWikiSummary(title: title, pageURL: pageURL)
                }
            }
            for await result in group {
                if let result { results.append(result) }
            }
        }
        return results
    }

    private func fetchWikiSummary(title: String, pageURL: String) async -> SearchResult? {
        let normalised = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = normalised.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return nil
        }
        guard let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extract = root["extract"] as? String, !extract.isEmpty else {
            return nil
        }
        return SearchResult(
            title: (root["title"] as? String) ?? title,
            snippet: extract,
            url: pageURL.isEmpty ? "https://en.wikipedia.org/wiki/\(normalised)" : pageURL
        )
    }
}
