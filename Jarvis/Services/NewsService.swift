import Foundation

/// One news headline. Source lets the UI render the right badge.
struct NewsHeadline: Identifiable, Equatable, Codable {
    enum Source: String, Codable, Identifiable, CaseIterable {
        case dr, tv2, bbc, cnn
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .dr: return "DR"
            case .tv2: return "TV2"
            case .bbc: return "BBC"
            case .cnn: return "CNN"
            }
        }
        var feedURL: URL {
            switch self {
            case .dr:  return URL(string: "https://www.dr.dk/nyheder/service/feeds/allenyheder")!
            case .tv2: return URL(string: "https://nyheder.tv2.dk/rss")!
            case .bbc: return URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!
            case .cnn: return URL(string: "https://rss.cnn.com/rss/edition.rss")!
            }
        }
    }

    let id: String              // GUID or URL (whichever the feed provides)
    let source: Source
    let title: String
    let link: URL?
    let publishedAt: Date?
}

/// Fetches RSS feeds in parallel and returns headline batches per source.
final class NewsService {
    /// Load fresh headlines for every source. Errors from individual feeds are logged
    /// but don't fail the overall result — the UI just won't show that section.
    func fetchAll(maxPerSource: Int = 8) async -> [NewsHeadline.Source: [NewsHeadline]] {
        var out: [NewsHeadline.Source: [NewsHeadline]] = [:]
        await withTaskGroup(of: (NewsHeadline.Source, [NewsHeadline]).self) { group in
            for source in NewsHeadline.Source.allCases {
                group.addTask { [self] in
                    let items = (try? await self.fetch(source: source, limit: maxPerSource)) ?? []
                    return (source, items)
                }
            }
            for await (source, items) in group {
                out[source] = items
            }
        }
        return out
    }

    func fetch(source: NewsHeadline.Source, limit: Int = 8) async throws -> [NewsHeadline] {
        var request = URLRequest(url: source.feedURL)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "News", code: 1)
        }
        let parser = RSSParser()
        var items = parser.parse(data: data, source: source)
        if items.count > limit { items = Array(items.prefix(limit)) }
        return items
    }
}

// MARK: - Minimal RSS parser built on Foundation's XMLParser

private final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [NewsHeadline] = []
    private var currentElement = ""
    private var inItem = false
    private var buffer = ""
    private var itemTitle = ""
    private var itemLink = ""
    private var itemGUID = ""
    private var itemDate = ""
    private var source: NewsHeadline.Source = .dr

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ]
        return formats.map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            return df
        }
    }()

    func parse(data: Data, source: NewsHeadline.Source) -> [NewsHeadline] {
        self.source = source
        items.removeAll()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    // MARK: XMLParserDelegate
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName.lowercased()
        if currentElement == "item" || currentElement == "entry" {
            inItem = true
            itemTitle = ""; itemLink = ""; itemGUID = ""; itemDate = ""
        } else if currentElement == "link" && inItem, let href = attributeDict["href"], itemLink.isEmpty {
            // Atom <link href="..."/> form
            itemLink = href
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inItem, let string = String(data: CDATABlock, encoding: .utf8) {
            buffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem {
            switch name {
            case "title":  itemTitle = trimmed
            case "link":   if itemLink.isEmpty { itemLink = trimmed }
            case "guid", "id": itemGUID = trimmed
            case "pubdate", "published", "updated": itemDate = trimmed
            default: break
            }
        }

        if name == "item" || name == "entry" {
            let id = itemGUID.isEmpty ? itemLink : itemGUID
            let date = Self.parseDate(itemDate)
            let link = URL(string: itemLink)
            if !itemTitle.isEmpty {
                items.append(NewsHeadline(
                    id: id.isEmpty ? UUID().uuidString : id,
                    source: source,
                    title: decodeHTMLEntities(itemTitle),
                    link: link,
                    publishedAt: date
                ))
            }
            inItem = false
        }
        buffer = ""
    }

    private static func parseDate(_ string: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private func decodeHTMLEntities(_ input: String) -> String {
        var result = input
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#039;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        return result
    }
}
