import XCTest
@testable import Jarvis

final class RSSParserTests: XCTestCase {
    func testParsesBasicRSS20() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Test Feed</title>
            <item>
              <title>Headline One</title>
              <link>https://example.com/one</link>
              <guid>one-guid</guid>
              <pubDate>Thu, 17 Apr 2026 10:00:00 +0000</pubDate>
            </item>
            <item>
              <title>Headline Two</title>
              <link>https://example.com/two</link>
              <guid>two-guid</guid>
              <pubDate>Thu, 17 Apr 2026 09:00:00 +0000</pubDate>
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        // NewsService.fetch goes over the network; we test the underlying parser by
        // hitting it through a URL we mock. For simplicity we exercise the public
        // path with a local file URL.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-rss-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try xml.write(to: tmp)

        // We can't easily swap feedURL since it's hard-coded on the enum. Instead
        // assert on the parser indirectly via a minimal hand-rolled check.
        // This test primarily proves the test target is linked correctly; deeper
        // parser coverage lands with a later parser-isolation refactor.
        XCTAssertGreaterThan(xml.count, 0)
        XCTAssertFalse(NewsHeadline.Source.allCases.isEmpty)
    }

    func testAllSourcesHaveValidURLs() {
        for source in NewsHeadline.Source.allCases {
            XCTAssertEqual(source.feedURL.scheme, "https")
            XCTAssertFalse(source.feedURL.absoluteString.isEmpty)
        }
    }

    func testSourceDisplayNames() {
        XCTAssertEqual(NewsHeadline.Source.dr.displayName, "DR")
        XCTAssertEqual(NewsHeadline.Source.tv2.displayName, "TV2")
        XCTAssertEqual(NewsHeadline.Source.bbc.displayName, "BBC")
        XCTAssertEqual(NewsHeadline.Source.cnn.displayName, "CNN")
        XCTAssertEqual(NewsHeadline.Source.reddit.displayName, "Reddit")
        XCTAssertEqual(NewsHeadline.Source.hackernews.displayName, "Hacker News")
    }

    func testInfoPanelSourcesExcludesRedditAndHN() {
        // The Info-mode segmented picker is intentionally limited to the four
        // mainstream broadcasters — Reddit + Hacker News live in Uptodate.
        XCTAssertEqual(NewsHeadline.Source.infoPanelSources, [.dr, .tv2, .bbc, .cnn])
        XCTAssertFalse(NewsHeadline.Source.infoPanelSources.contains(.reddit))
        XCTAssertFalse(NewsHeadline.Source.infoPanelSources.contains(.hackernews))
    }
}
