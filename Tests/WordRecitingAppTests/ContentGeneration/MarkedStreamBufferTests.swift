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
}
