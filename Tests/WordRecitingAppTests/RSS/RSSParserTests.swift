import XCTest
@testable import WordRecitingApp

final class RSSParserTests: XCTestCase {

    private let rssXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
      <channel>
        <title>Test Feed</title>
        <item>
          <title>First Story</title>
          <link>https://example.com/1</link>
          <description>This is the first story body.</description>
          <content:encoded><![CDATA[<p>Full first story body with many details.</p><p>Second paragraph.</p>]]></content:encoded>
          <guid>https://example.com/1</guid>
          <pubDate>Mon, 10 Aug 2026 12:00:00 GMT</pubDate>
        </item>
        <item>
          <title>Second Story</title>
          <link>https://example.com/2</link>
          <description>Second story body.</description>
          <guid>uid-2</guid>
          <pubDate>Sun, 09 Aug 2026 08:30:00 +0000</pubDate>
        </item>
      </channel>
    </rss>
    """

    private let atomXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Atom Feed</title>
      <entry>
        <title>Atom Entry</title>
        <link href="https://example.com/a1"/>
        <summary>Atom summary text.</summary>
        <content type="html">Atom full content body.</content>
        <id>tag:example,2026:a1</id>
        <updated>2026-08-10T12:00:00Z</updated>
      </entry>
    </feed>
    """

    // MARK: - RSS 2.0

    func testParseRSSItems() throws {
        let items = try RSSParser.parse(data: Data(rssXML.utf8))
        XCTAssertEqual(items.count, 2)

        XCTAssertEqual(items[0].title, "First Story")
        XCTAssertEqual(items[0].link, "https://example.com/1")
        XCTAssertEqual(items[0].summary, "This is the first story body.")
        XCTAssertEqual(items[0].content,
                       "<p>Full first story body with many details.</p><p>Second paragraph.</p>")
        XCTAssertEqual(items[0].id, "https://example.com/1")
        XCTAssertNotNil(items[0].pubDate)

        XCTAssertEqual(items[1].title, "Second Story")
        XCTAssertEqual(items[1].id, "uid-2")
        XCTAssertTrue(items[1].content.isEmpty, "无 content:encoded 的条目 content 为空")
    }

    func testParseRSSDateRFC822() throws {
        let items = try RSSParser.parse(data: Data(rssXML.utf8))
        // RFC822 的 "GMT" 表示 UTC 时刻；用 UTC 时区拆解验证绝对时间
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                       from: try XCTUnwrap(items[0].pubDate))
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 8)
        XCTAssertEqual(comps.day, 10)
        XCTAssertEqual(comps.hour, 12)
    }

    // MARK: - Atom

    func testParseAtomEntry() throws {
        let items = try RSSParser.parse(data: Data(atomXML.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Atom Entry")
        XCTAssertEqual(items[0].link, "https://example.com/a1")
        XCTAssertEqual(items[0].summary, "Atom summary text.")
        XCTAssertEqual(items[0].content, "Atom full content body.")
        XCTAssertEqual(items[0].id, "tag:example,2026:a1")
        XCTAssertNotNil(items[0].pubDate)
    }

    // MARK: - 无效 XML

    func testParseInvalidXMLThrows() {
        XCTAssertThrowsError(try RSSParser.parse(data: Data("<not xml".utf8)))
    }

    // MARK: - HTML 清洗

    func testCleanedTextStripsHTML() {
        let raw = "<p>Hello <b>world</b> &amp; friends.</p><p>Second para.</p>"
        let cleaned = raw.rssCleanedText()
        XCTAssertEqual(cleaned, "Hello world & friends.\nSecond para.")
    }

    func testCleanedTextStripsScriptBlock() {
        let raw = "Keep this. <script>var x = 1;</script> Done."
        let cleaned = raw.rssCleanedText()
        XCTAssertFalse(cleaned.contains("var x"))
        XCTAssertTrue(cleaned.contains("Keep this"))
    }
}
