import XCTest
@testable import WordRecitingApp

final class WordNormalizerTests: XCTestCase {

    // MARK: - 规则后缀剥离

    func testPluralS() {
        XCTAssertEqual(WordNormalizer.normalize("battles"), "battle")
        // sees 长度 4 不剥（-s 阈值需剩 >4，防 this/was/his）
        XCTAssertEqual(WordNormalizer.normalize("sees"), "sees")
        XCTAssertEqual(WordNormalizer.normalize("books"), "book")
    }

    func testPluralEs() {
        XCTAssertEqual(WordNormalizer.normalize("boxes"), "box")
        XCTAssertEqual(WordNormalizer.normalize("watches"), "watch")
        XCTAssertEqual(WordNormalizer.normalize("glasses"), "glass")
        XCTAssertEqual(WordNormalizer.normalize("buses"), "bus")
    }

    func testIesAndIed() {
        XCTAssertEqual(WordNormalizer.normalize("studies"), "study")
        XCTAssertEqual(WordNormalizer.normalize("studied"), "study")
    }

    func testIng() {
        XCTAssertEqual(WordNormalizer.normalize("running"), "run")
        XCTAssertEqual(WordNormalizer.normalize("reading"), "read")
    }

    func testEd() {
        XCTAssertEqual(WordNormalizer.normalize("walked"), "walk")
        XCTAssertEqual(WordNormalizer.normalize("stopped"), "stop")
        XCTAssertEqual(WordNormalizer.normalize("abandoned"), "abandon")
    }

    /// -er/-est 不再剥离（weather/water/paper 误伤率高）：比较级词形作为独立 lemma。
    func testErEst() {
        XCTAssertEqual(WordNormalizer.normalize("bigger"), "bigger")
        XCTAssertEqual(WordNormalizer.normalize("biggest"), "biggest")
    }

    func testLy() {
        XCTAssertEqual(WordNormalizer.normalize("quickly"), "quick")
        // slowly 长度 6 不剥（-ly 阈值需剩 >6，防 reply/family）
        XCTAssertEqual(WordNormalizer.normalize("slowly"), "slowly")
    }

    // MARK: - 保守：短词不误剥

    func testShortWordsNotOverStripped() {
        XCTAssertEqual(WordNormalizer.normalize("bus"), "bus")
        XCTAssertEqual(WordNormalizer.normalize("is"), "is")
        XCTAssertEqual(WordNormalizer.normalize("run"), "run")
        XCTAssertEqual(WordNormalizer.normalize("gas"), "gas")
    }

    // MARK: - 清洗：剥离音标 / 词性尾巴

    func testCleansPhoneticTail() {
        XCTAssertEqual(WordNormalizer.normalize("abandon[ə'bændən]"), "abandon")
        XCTAssertEqual(WordNormalizer.normalize("battle['bætl]"), "battle")
    }

    func testCleansPosTail() {
        XCTAssertEqual(WordNormalizer.normalize("abandon (v.)"), "abandon")
        XCTAssertEqual(WordNormalizer.normalize("abandon v."), "abandon")
    }

    func testCleanKeepsHyphenAndApostrophe() {
        XCTAssertEqual(WordNormalizer.clean("well-known"), "well-known")
        XCTAssertEqual(WordNormalizer.clean("o'clock"), "o'clock")
    }

    // MARK: - 词组 / 大小写

    func testPhraseKeptAsIs() {
        XCTAssertEqual(WordNormalizer.normalize("take up"), "take up")
        XCTAssertEqual(WordNormalizer.normalize("give in"), "give in")
    }

    func testCaseInsensitiveNormalization() {
        XCTAssertEqual(WordNormalizer.normalize("Battles"), "battle")
        XCTAssertEqual(WordNormalizer.normalize("STUDIES"), "study")
    }

    func testEmptyAndSymbols() {
        XCTAssertEqual(WordNormalizer.normalize(""), "")
        XCTAssertEqual(WordNormalizer.normalize("[音标]"), "")
    }
}
