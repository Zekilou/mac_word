import XCTest
@testable import WordRecitingApp

final class ArticleExtractorTests: XCTestCase {

    func testArticleSectionPreferred() {
        let html = """
        <html><body>
        <nav>Menu link one link two</nav>
        <article>
          <h1>Title</h1>
          <p>First full paragraph about the weather today.</p>
          <p>Second full paragraph describing the storm approaching.</p>
        </article>
        <footer>Copyright footer text here</footer>
        </body></html>
        """
        let text = ArticleExtractor.extract(from: html)
        XCTAssertTrue(text.contains("First full paragraph"))
        XCTAssertTrue(text.contains("Second full paragraph"))
        XCTAssertFalse(text.contains("Menu"), "导航不应混入正文")
        XCTAssertFalse(text.contains("Copyright"), "页脚不应混入正文")
    }

    func testFallsBackToParagraphsWithoutArticle() {
        let html = """
        <html><body><div>
        <p>No article tag here but still full paragraphs.</p>
        <p>Another paragraph with plenty of content words.</p>
        </div></body></html>
        """
        let text = ArticleExtractor.extract(from: html)
        XCTAssertTrue(text.contains("No article tag"))
        XCTAssertTrue(text.contains("Another paragraph"))
    }

    func testFallsBackToWholePageCleaning() {
        let html = "<html><body><div>Only plain text content without tags and no paragraphs anywhere.</div></body></html>"
        let text = ArticleExtractor.extract(from: html)
        XCTAssertTrue(text.contains("Only plain text"))
    }

    func testShortBodyReturnsEmpty() {
        // <p> 内容不足 40 字符 → 视为无有效正文
        let html = "<article><p>Short.</p></article>"
        XCTAssertEqual(ArticleExtractor.extract(from: html), "")
    }

    func testArticleWithRawTextNoParagraphs() {
        // <article> 内无 <p>，但清洗后正文 ≥ 40 字符 → 用 article 清洗结果
        let html = """
        <article><div>This article has long plain text without paragraph tags, enough to pass the length threshold and be returned as the article body.</div></article>
        """
        let text = ArticleExtractor.extract(from: html)
        XCTAssertTrue(text.contains("This article has long plain text"))
    }

    /// 回归：大小写不敏感的区域提取不得跨字符串用索引（会崩溃）。
    /// @ai: 旧实现用 `html.lowercased()` 求 Range 再切 `html`。小写化会改变 UTF-8 长度
    ///      （İ U+0130 由 2 字节变 3 字节，共 27 个此类字符），两个串的 String.Index
    ///      不可互换 → "Fatal error: String index range is out of bounds"。
    ///      这里是崩溃复现输入（12 个 İ 即可越界）。
    func testSectionHandlesLowercaseLengthChangingCharacters() {
        let longTail = " trailing text that is definitely long enough to pass the forty character threshold."
        for n in [1, 12, 50, 200] {
            let body = String(repeating: "\u{0130}", count: n)
            let html = "<ARTICLE>\(body)\(longTail)</ARTICLE>"
            // 旧实现在 n>=12 时 SIGTRAP 崩溃；修复后必须安全返回内容
            let text = ArticleExtractor.extract(from: html)
            XCTAssertTrue(text.contains("trailing text"),
                          "n=\(n) 不应崩溃且应提取到内容，实际：\(text.prefix(40))")
        }
    }

    /// 回归：大写标签 + 非 ASCII 扩展字符组合仍能正确提取。
    func testSectionCaseInsensitiveMixedWithUnicode() {
        let iDot = "\u{0130}"
        let html = "<Article><p>Straße und \(iDot)stanbul sind Orte mit viel Text, der lang genug ist.</p></Article>"
        let text = ArticleExtractor.extract(from: html)
        XCTAssertTrue(text.contains("stanbul"), "应提取到正文，实际：\(text.prefix(60))")
    }
}
