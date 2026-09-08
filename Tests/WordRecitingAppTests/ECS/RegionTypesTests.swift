import XCTest
@testable import WordRecitingApp

/// 阶段一：region / 词事件 / 词频坐标的合同枚举。
final class RegionTypesTests: XCTestCase {

    func testRegionKindRawValues() {
        XCTAssertEqual(RegionKind.study.rawValue, "study")
        XCTAssertEqual(RegionKind.rss.rawValue, "rss")
        XCTAssertEqual(RegionKind.generate.rawValue, "generate")
        XCTAssertEqual(RegionKind.dictionary.rawValue, "dictionary")
        XCTAssertEqual(RegionKind.initSession.rawValue, "init")
        XCTAssertEqual(RegionKind.allCases.count, 5)
    }

    func testWordEventKindRawValues() {
        XCTAssertEqual(WordEventKind.seen.rawValue, "seen")
        XCTAssertEqual(WordEventKind.lookup.rawValue, "lookup")
        XCTAssertEqual(WordEventKind.markKnown.rawValue, "mark_known")
        XCTAssertEqual(WordEventKind.markUnknown.rawValue, "mark_unknown")
        XCTAssertEqual(WordEventKind.quizCorrect.rawValue, "quiz_correct")
        XCTAssertEqual(WordEventKind.quizWrong.rawValue, "quiz_wrong")
        XCTAssertEqual(WordEventKind.allCases.count, 6)
    }

    /// 合同铁律：新 case 只能追加到末尾，既有 rawValue 不得变动。
    func testNewCasesAppendedAtEnd() {
        XCTAssertEqual(NodeKind.allCases.last, .region)
        XCTAssertEqual(Array(ComponentID.allCases.suffix(3)),
                       [.region, .wordEvent, .lemmaFrequency])
        XCTAssertEqual(ComponentID.region.rawValue, "region")
        XCTAssertEqual(ComponentID.wordEvent.rawValue, "word_event")
        XCTAssertEqual(ComponentID.lemmaFrequency.rawValue, "lemma_frequency")
    }

    func testWordEventKindRoundTrip() throws {
        let data = try JSONEncoder().encode(WordEventKind.quizWrong)
        XCTAssertEqual(try JSONDecoder().decode(WordEventKind.self, from: data), .quizWrong)
    }

    func testRegionKindRoundTrip() throws {
        let data = try JSONEncoder().encode(RegionKind.initSession)
        XCTAssertEqual(try JSONDecoder().decode(RegionKind.self, from: data), .initSession)
    }
}
