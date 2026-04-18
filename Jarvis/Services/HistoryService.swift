import Foundation

/// A single "on this day" historical event from Wikipedia.
struct HistoryEvent: Identifiable, Equatable {
    let id: String
    let year: Int
    let text: String
    let pageURL: URL?
}

enum HistoryServiceError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "On-this-day API returned an invalid response"
        case .httpError(let code): return "On-this-day API HTTP \(code)"
        }
    }
}

/// Wikipedia "On this day" events. Public REST endpoint, no key, no rate-limit
/// in practice for a per-day request. Docs:
/// https://en.wikipedia.org/api/rest_v1/#/Feed/onThisDay
final class HistoryService {
    /// Returns today's notable events, newest-first by year. `limit` caps the
    /// list (Wikipedia typically returns 40–60 events per day for the English
    /// wiki, which is overkill for the Uptodate panel).
    func fetchToday(limit: Int = 5) async throws -> [HistoryEvent] {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.month, .day], from: Date())
        guard let month = components.month, let day = components.day else {
            throw HistoryServiceError.invalidResponse
        }

        let mm = String(format: "%02d", month)
        let dd = String(format: "%02d", day)
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/feed/onthisday/events/\(mm)/\(dd)") else {
            throw HistoryServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Jarvis/\(Constants.appVersion) (macOS menu-bar assistant)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HistoryServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HistoryServiceError.httpError(http.statusCode)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            throw HistoryServiceError.invalidResponse
        }

        var out: [HistoryEvent] = []
        for entry in events {
            guard let year = entry["year"] as? Int,
                  let text = entry["text"] as? String else { continue }

            let pages = entry["pages"] as? [[String: Any]]
            let pageURL: URL? = {
                guard let first = pages?.first,
                      let contentURLs = first["content_urls"] as? [String: Any],
                      let desktop = contentURLs["desktop"] as? [String: Any],
                      let urlString = desktop["page"] as? String else {
                    return nil
                }
                return URL(string: urlString)
            }()

            out.append(HistoryEvent(
                id: "\(year)-\(text.hashValue)",
                year: year,
                text: text,
                pageURL: pageURL
            ))
            if out.count >= limit { break }
        }
        return out.sorted { $0.year > $1.year }
    }
}
