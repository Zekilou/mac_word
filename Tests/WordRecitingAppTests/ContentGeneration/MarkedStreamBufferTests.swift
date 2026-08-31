import XCTest
@testable import WordRecitingApp

/// 输出约定标记的流式剥离：跨块识别、思考前置跳过、结束标记剥离、无标记回退全量。
final class MarkedStreamBufferTests: XCTestCase {

    func testStripsOpeningAndClosing() {
        var b = MarkedStreamBuffer()
        let c1 = b.append("===ARTICLE_START===The world is changing.")
        XCTAssertEqual(c1, "The world is changing.")
        XCTAssertEqual(b.append(" It keeps moving."), " It keeps moving.")
        let c2 = b.append("===ARTICLE_END===")
        XCTAssertEqual(c2, "")
        XCTAssertEqual(b.finalize(), "The world is changing. It keeps moving.")
    }

    func testOpeningSplitAcrossChunks() {
        var b = MarkedStreamBuffer()
        XCTAssertEqual(b.append("===ARTICLE_"), "")
        XCTAssertEqual(b.append("START===\nHello there."), "\nHello there.")
        XCTAssertEqual(b.finalize(), "\nHello there.")
    }

    func testSkipsThinkingBeforeOpening() {
        var b = MarkedStreamBuffer()
        let c1 = b.append("Sure! Here is the article.\n===ARTICLE_START===Hello.")
        XCTAssertEqual(c1, "Hello.")
        XCTAssertEqual(b.finalize(), "Hello.")
    }

    func testNoOpeningMarkerFallsBackToWhole() {
        var b = MarkedStreamBuffer()
        let c1 = b.append("Just a plain answer with no markers at all.")
        XCTAssertEqual(c1, "Just a plain answer with no markers at all.")
        XCTAssertEqual(b.finalize(), "Just a plain answer with no markers at all.")
    }

    func testClosingSplitAcrossChunks() {
        var b = MarkedStreamBuffer()
        _ = b.append("===ARTICLE_START===Body text")
        XCTAssertEqual(b.append("===ARTICLE_"), "")
        XCTAssertEqual(b.append("END===tail junk"), "")
        XCTAssertEqual(b.finalize(), "Body text")
    }

    func testPartialClosingAtStreamEndIsDropped() {
        var b = MarkedStreamBuffer()
        _ = b.append("===ARTICLE_START===Body text")
        XCTAssertEqual(b.append("===ARTICLE_END"), "")
        XCTAssertEqual(b.finalize(), "Body text", "结尾半截结束标记应被丢弃")
    }

    func testRawAllKeepsOriginal() {
        var b = MarkedStreamBuffer()
        _ = b.append("===ARTICLE_START===Hi.")
        _ = b.append(" Bye.===ARTICLE_END===")
        XCTAssertEqual(b.rawAll, "===ARTICLE_START===Hi. Bye.===ARTICLE_END===")
        XCTAssertEqual(b.body, "Hi. Bye.")
    }

    // MARK: - 实时前导垃圾守卫（LeadingLineGuard）

    func testGuardEmitsNormalContentImmediately() {
        var g = LeadingLineGuard()
        XCTAssertEqual(g.append("A good writer must master"), "A good writer must master",
                       "普通正文应立即放行")
        XCTAssertEqual(g.append(" style."), " style.")
    }

    func testGuardDropsLeadingOutlineLines() {
        var g = LeadingLineGuard()
        XCTAssertEqual(g.append("- Paragraph 1: The craft of writing.\n"), "",
                       "大纲行应被扣留并丢弃")
        XCTAssertEqual(g.append("- Paragraph 2: Body ideas\n\n"), "",
                       "后续大纲行与空行也应丢弃")
        XCTAssertEqual(g.append("A real article begins here.\n"), "A real article begins here.\n",
                       "正文开始后放行")
    }

    func testGuardDropsMetaPreambleLine() {
        var g = LeadingLineGuard()
        XCTAssertEqual(g.append("I'm not sure whether my draft is ready.\n"), "",
                       "任务元句应被丢弃")
        XCTAssertEqual(g.append("Here is the article.\n"), "Here is the article.\n")
    }

    func testGuardKeepsBulletContent() {
        var g = LeadingLineGuard()
        XCTAssertEqual(g.append("- This is a bullet point.\n"), "- This is a bullet point.\n",
                       "bullet 内容行（非大纲）应保留")
    }
}
