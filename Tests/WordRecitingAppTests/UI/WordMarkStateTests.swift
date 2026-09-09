import XCTest
@testable import WordRecitingApp

final class WordMarkStateTests: XCTestCase {

    private func assertLearning(_ state: WordMarkState, _ expected: Double,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .learning(let belief) = state else {
            XCTFail("expected .learning, got \(state)", file: file, line: line)
            return
        }
        XCTAssertEqual(belief, expected, accuracy: 0.0001, file: file, line: line)
    }

    // MARK: - 概率主口径

    func testBeliefDrivesState() {
        XCTAssertEqual(WordMarkState.from(belief: 0.95, mastery: 1.0, seenCount: 0), .known)
        XCTAssertEqual(WordMarkState.from(belief: 0.10, mastery: 2.0, seenCount: 0), .unknown)
        assertLearning(WordMarkState.from(belief: 0.5, mastery: 2.0, seenCount: 0), 0.5)
    }

    func testThresholdsAreInclusive() {
        XCTAssertEqual(WordMarkState.from(belief: 0.85, mastery: nil, seenCount: 0), .known)
        XCTAssertEqual(WordMarkState.from(belief: 0.851, mastery: nil, seenCount: 0), .known)
        XCTAssertEqual(WordMarkState.from(belief: 0.20, mastery: nil, seenCount: 0), .unknown)
        XCTAssertEqual(WordMarkState.from(belief: 0.199, mastery: nil, seenCount: 0), .unknown)
    }

    func testBeliefOverridesExplicitMastery() {
        // 用户标了「会」，但模型概率低 → 以概率为准
        XCTAssertEqual(WordMarkState.from(belief: 0.15, mastery: 2.0, seenCount: 3), .unknown)
    }

    // MARK: - 无概率时回退显式标记

    func testFallsBackToMasteryWhenNoBelief() {
        XCTAssertEqual(WordMarkState.from(belief: nil, mastery: 2.0, seenCount: 0), .known)
        XCTAssertEqual(WordMarkState.from(belief: nil, mastery: 1.0, seenCount: 0), .unknown)
        XCTAssertEqual(WordMarkState.from(belief: nil, mastery: nil, seenCount: 3), .seen)
        XCTAssertEqual(WordMarkState.from(belief: nil, mastery: nil, seenCount: 0), .pending)
    }

    func testMasteryMapsLinearlyToBeliefInLearningBand() {
        assertLearning(WordMarkState.from(belief: nil, mastery: 1.5, seenCount: 0), 0.5)
        assertLearning(WordMarkState.from(belief: nil, mastery: 1.2, seenCount: 0), 0.2)
    }

    // MARK: - 展示

    func testLearningLabelShowsPercent() {
        XCTAssertEqual(WordMarkState.learning(0.5).label, "学习中 50%")
    }

    func testLabels() {
        XCTAssertEqual(WordMarkState.known.label, "已会")
        XCTAssertEqual(WordMarkState.unknown.label, "不会")
        XCTAssertEqual(WordMarkState.seen.label, "出现过")
        XCTAssertEqual(WordMarkState.pending.label, "无记录")
    }

    func testThresholdsAreExposed() {
        XCTAssertEqual(WordMarkState.knownThreshold, 0.85, accuracy: 0.0001)
        XCTAssertEqual(WordMarkState.unknownThreshold, 0.20, accuracy: 0.0001)
    }

    // MARK: - 图例统一

    func testLegendItemsCoverAllTiers() {
        let labels = WordMarkState.legendItems.map(\.label)
        XCTAssertEqual(labels, ["会", "学习中", "不会", "出现过", "未见"])
    }

    func testLegendColorsComeFromStateColors() {
        let items = WordMarkState.legendItems
        XCTAssertEqual(items[0].color, WordMarkState.known.color)
        XCTAssertEqual(items[1].color, WordMarkState.learning(0.5).color)
        XCTAssertEqual(items[2].color, WordMarkState.unknown.color)
    }
}
