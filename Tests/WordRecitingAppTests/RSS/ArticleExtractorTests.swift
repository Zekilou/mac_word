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
}
