import XCTest
import GRDB
@testable import WordRecitingApp

@MainActor
final class RSSViewModelTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var store: RSSSourceStore!
    private var vm: RSSViewModel!

    private static let httpResponse = HTTPURLResponse(
        url: URL(string: "https://test.local")!,
        statusCode: 200, httpVersion: nil, headerFields: nil)!

    private let rssXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Test Feed</title>
        <item>
          <title>Weather today</title>
          <link>https://example.com/1</link>
          <description>The weather is warm and sunny today.</description>
          <guid>1</guid>
          <pubDate>Mon, 10 Aug 2026 12:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
    """

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        store = RSSSourceStore(defaults: UserDefaults(
            suiteName: "test-rss-\(UUID().uuidString)")!)
        vm = RSSViewModel(world: world, store: store)
        // 注入 mock 网络：所有请求返回测试 RSS
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "https://test.local")!,
                             statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("""
             <?xml version="1.0"?>
             <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>
             <item><title>Weather today</title><link>https://example.com/1</link>
             <description>The weather is warm and sunny today.</description>
             <content:encoded><![CDATA[<p>The weather is warm and sunny today.</p><p>Many people enjoy the sunny weather by the sea.</p>]]></content:encoded>
             <guid>1</guid></item>
             </channel></rss>
             """.utf8))
        }
        vm.sessionOverride = URLSession(configuration: config)
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    /// 轮询等待 items 填充。
    private func waitForItems(_ target: Int) async {
        for _ in 0..<100 where vm.items.count < target {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 轮询等待文章加载完成（抓原文为异步，words 非空且不在抓取中）。
    private func waitForArticle() async {
        for _ in 0..<100 where vm.words.isEmpty || vm.isFetchingArticle {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 源

    func testBuiltInSourcesPresent() {
        XCTAssertGreaterThan(vm.sources.count, 0)
        XCTAssertTrue(vm.sources.contains { $0.builtIn })
    }

    func testFetchSourceParsesItems() async throws {
        let src = try XCTUnwrap(vm.sources.first)
        vm.selectSource(src.id)
        await waitForItems(1)
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.title, "Weather today")
    }

    // MARK: - 阅读：自动 seen，不判定会/不会

    func testSelectArticleMarksSeenNotKnown() async throws {
        let src = try XCTUnwrap(vm.sources.first)
        vm.selectSource(src.id)
        await waitForItems(1)

        vm.selectArticle(try XCTUnwrap(vm.items.first))
        XCTAssertFalse(vm.words.isEmpty, "应提取词元")
        // 全文优先：content:encoded 两段 > summary 一句
        XCTAssertEqual(vm.articleText,
                       "The weather is warm and sunny today.\nMany people enjoy the sunny weather by the sea.")

        // 全部词写入 seen（mastery=0），不判定会/不会
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_user_known"), vm.words.count)
        let weather = try XCTUnwrap(vm.words.first { $0.lemma == "weather" })
        let lemmaId = try XCTUnwrap(world.graph.findLemmaId(byTextA: "weather"))
        XCTAssertEqual(try world.graph.lemmaMastery(lemmaId: lemmaId), 0.0,
                       "出现过但不判定会/不会")
        XCTAssertEqual(vm.markState(for: weather), .seen, "词块应为蓝色（出现过）")
    }

    func testToggleSeenToUnknownThenKnown() async throws {
        let src = try XCTUnwrap(vm.sources.first)
        vm.selectSource(src.id)
        await waitForItems(1)
        vm.selectArticle(try XCTUnwrap(vm.items.first))

        let weather = try XCTUnwrap(vm.words.first { $0.lemma == "weather" })
        XCTAssertEqual(vm.markState(for: weather), .seen)

        // 蓝（seen）点击 → 红（不会）
        vm.toggle(weather)
        XCTAssertEqual(vm.markState(for: weather), .unknown)
        let lemmaId = try XCTUnwrap(world.graph.findLemmaId(byTextA: "weather"))
        XCTAssertEqual(try world.graph.lemmaMastery(lemmaId: lemmaId), 1.0)

        // 红点击 → 绿（会）
        vm.toggle(weather)
        XCTAssertEqual(vm.markState(for: weather), .known)
        XCTAssertEqual(try world.graph.lemmaMastery(lemmaId: lemmaId), 2.0)
    }

    // MARK: - 只有摘要的源 → 抓原文提取正文

    func testFetchFullArticleWhenOnlySummary() async throws {
        // 源 RSS 无 content:encoded（只有摘要）；原文链接返回可提取正文的 HTML
        StubURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("example.com") {
                // 原文页面
                return (Self.httpResponse, Data("""
                    <html><body><nav>Nav menu items here</nav>
                    <article><p>Authorities issued a severe storm warning for coastal areas today.</p>
                    <p>Residents should prepare for heavy rain and strong winds throughout the evening.</p></article>
                    </body></html>
                    """.utf8))
            }
            // 源 RSS（无 content:encoded，只有摘要）
            return (Self.httpResponse,
                    Data("""
                    <?xml version="1.0"?>
                    <rss version="2.0"><channel>
                    <item><title>Storm warning</title><link>https://example.com/1</link>
                    <description>Storm warning summary text only.</description><guid>1</guid></item>
                    </channel></rss>
                    """.utf8))
        }
        let src = try XCTUnwrap(vm.sources.first)
        vm.selectSource(src.id)
        await waitForItems(1)
        vm.selectArticle(try XCTUnwrap(vm.items.first))
        await waitForArticle()

        XCTAssertFalse(vm.words.isEmpty, "应提取词元")
        XCTAssertTrue(vm.articleText.contains("Authorities issued a severe storm warning"),
                      "应使用抓取提取的正文")
        XCTAssertTrue(vm.articleText.contains("Residents should prepare"),
                      "正文应含第二段")
        XCTAssertFalse(vm.articleText.contains("Nav menu"), "导航不应混入正文")
    }

    func testFetchFailsFallsBackToSummary() async throws {
        // 原文链接请求失败 → 回退摘要
        StubURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("example.com") {
                throw URLError(.cannotConnectToHost)
            }
            return (Self.httpResponse,
                    Data("""
                    <?xml version="1.0"?>
                    <rss version="2.0"><channel>
                    <item><title>Storm warning</title><link>https://example.com/1</link>
                    <description>Storm warning summary text only.</description><guid>1</guid></item>
                    </channel></rss>
                    """.utf8))
        }
        let src = try XCTUnwrap(vm.sources.first)
        vm.selectSource(src.id)
        await waitForItems(1)
        vm.selectArticle(try XCTUnwrap(vm.items.first))
        await waitForArticle()

        XCTAssertEqual(vm.articleText, "Storm warning summary text only.", "抓取失败回退摘要")
        XCTAssertNil(vm.errorMessage, "有摘要时静默回退，不报错")
    }

    // MARK: - 已有会/不会的词不受 seen 影响

    func testKnownWordStaysGreenAfterSeen() async throws {
        // 预置 weather = 会
        try world.run(UserKnownSystem(), context: .batch(
            words: [("weather", true)], source: "init"))

        let src = try XCTUnwrap(vm.sources.first)
        vm.selectSource(src.id)
        await waitForItems(1)
        vm.selectArticle(try XCTUnwrap(vm.items.first))

        let weather = try XCTUnwrap(vm.words.first { $0.lemma == "weather" })
        XCTAssertEqual(vm.markState(for: weather), .known, "已有会记录保持绿")
    }
}

// MARK: - URLSession stub

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
