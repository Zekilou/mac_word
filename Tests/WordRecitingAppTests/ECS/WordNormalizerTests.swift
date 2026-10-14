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

    /// 回归：本身以 -s 结尾的单数词不得被砍掉尾字母。
    /// @ai: 旧实现只看输入长度，`class`→`clas`、`process`→`proces`、`business`→`busines`，
    ///      导致单数与复数归一化成**两个不同 lemma**，违背「全库唯一 key」契约。
    func testSingularSWordsAreNotStripped() {
        for w in ["class", "process", "glass", "business", "address", "focus",
                  "status", "virus", "campus", "analysis", "basis", "crisis"] {
            XCTAssertEqual(WordNormalizer.normalize(w), w,
                           "\(w) 是单数词，不应被 -s 剥离")
        }
    }

    /// 回归：单数与复数必须归一化到同一 lemma（key 唯一性契约）。
    func testSingularAndPluralNormalizeToSameKey() {
        let pairs = [("class", "classes"), ("process", "processes"),
                     ("glass", "glasses"), ("business", "businesses"),
                     ("address", "addresses"), ("box", "boxes"),
                     ("battle", "battles"), ("book", "books")]
        for (singular, plural) in pairs {
            XCTAssertEqual(WordNormalizer.normalize(singular),
                           WordNormalizer.normalize(plural),
                           "\(singular)/\(plural) 应归一化到同一 lemma")
        }
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
