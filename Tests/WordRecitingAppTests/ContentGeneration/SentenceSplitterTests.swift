import XCTest
@testable import WordRecitingApp

/// 正则断句：缩写保护 + 引号内句号不切分。
final class SentenceSplitterTests: XCTestCase {

    func testSplitsOnPeriod() {
        let s = SentenceSplitter.split("Hello world. This is next.")
        XCTAssertEqual(s, ["Hello world.", "This is next."])
    }

    func testSplitsOnQuestionAndExclamation() {
        let s = SentenceSplitter.split("Are you ok? Yes! Great.")
        XCTAssertEqual(s, ["Are you ok?", "Yes!", "Great."])
    }

    func testKeepsAbbreviationTogether() {
        let s = SentenceSplitter.split("Dr. Smith works at U.S. labs. He is busy.")
        XCTAssertEqual(s, ["Dr. Smith works at U.S. labs.", "He is busy."])
    }

    func testKeepsDecimalAndSentenceTogether() {
        let s = SentenceSplitter.split("Pi is 3.14 roughly. That is fine.")
        XCTAssertEqual(s, ["Pi is 3.14 roughly.", "That is fine."])
    }

    func testKeepsQuoteEndingPeriodWithSentence() {
        let s = SentenceSplitter.split("He said \"go now.\" Then he left.")
        XCTAssertEqual(s, ["He said \"go now.\"", "Then he left."])
    }

    func testSingleSentence() {
        let s = SentenceSplitter.split("Just one sentence here.")
        XCTAssertEqual(s, ["Just one sentence here."])
    }

    func testEmptyReturnsEmpty() {
        XCTAssertTrue(SentenceSplitter.split("").isEmpty)
    }
}
