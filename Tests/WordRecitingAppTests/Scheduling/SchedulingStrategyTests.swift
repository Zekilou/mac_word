import XCTest
@testable import WordRecitingApp

/// 最小可用的打分策略：按固定表打分，用于验证 WordSelector 的取词逻辑。
private struct StubScoring: WordScoringStrategy {
    let id: WordScoringID = .random
    let table: [EntityID: Double]
    func score(_ f: WordFeatures, context: ScoringContext) -> Double {
        table[f.lemmaId] ?? 0
    }
}

final class SchedulingStrategyTests: XCTestCase {

    // MARK: - 枚举（合同文件只追加）

    func testSchedulerIDKeepsExistingRawValues() {
        XCTAssertEqual(SchedulerID.sm2.rawValue, "sm-2")
        XCTAssertEqual(SchedulerID.fsrsV4.rawValue, "fsrs-v4")
        XCTAssertEqual(SchedulerID.sm2Frequency.rawValue, "sm-2-frequency")
        XCTAssertEqual(SchedulerID.allCases.last, .sm2Frequency, "新 case 只能追加到末尾")
    }

    func testWordScoringIDRawValues() {
        XCTAssertEqual(WordScoringID.random.rawValue, "random")
        XCTAssertEqual(WordScoringID.criticalWords.rawValue, "critical-words")
        XCTAssertEqual(WordScoringID.frequencyTier.rawValue, "frequency-tier")
        XCTAssertEqual(WordScoringID.allCases.count, 3)
    }

    // MARK: - WordSelector

    private func features(_ ids: [EntityID]) -> [WordFeatures] {
        ids.map { id in
            WordFeatures(lemmaId: id, belief: nil, band: nil, rank: nil,
                         eventCount: 0, contextCount: 0, lastEventAt: nil, card: nil)
        }
    }

    private let context = ScoringContext(purpose: .articleTargets,
                                         now: Date(), bandWindow: nil)

    func testTopNPicksHighestScores() {
        let strategy = StubScoring(table: ["L1": 0.1, "L2": 0.9, "L3": 0.5])
        let picked = WordSelector.top(2, from: features(["L1", "L2", "L3"]),
                                      strategy: strategy, context: context)
        XCTAssertEqual(picked, ["L2", "L3"])
    }

    func testTopNCapsAtAvailableCount() {
        let strategy = StubScoring(table: ["L1": 0.1])
        XCTAssertEqual(WordSelector.top(5, from: features(["L1"]),
                                        strategy: strategy, context: context), ["L1"])
    }

    func testTopNZeroOrEmptyReturnsEmpty() {
        let strategy = StubScoring(table: ["L1": 0.1])
        XCTAssertTrue(WordSelector.top(0, from: features(["L1"]),
                                       strategy: strategy, context: context).isEmpty)
        XCTAssertTrue(WordSelector.top(3, from: [],
                                       strategy: strategy, context: context).isEmpty)
    }

    func testThresholdPicksAboveAndSortsDescending() {
        let strategy = StubScoring(table: ["L1": 0.2, "L2": 0.8, "L3": 0.6])
        let picked = WordSelector.above(0.5, from: features(["L1", "L2", "L3"]),
                                        strategy: strategy, context: context)
        XCTAssertEqual(picked, ["L2", "L3"])
    }

    func testTiesAreStableByLemmaId() {
        let strategy = StubScoring(table: ["L1": 0.5, "L2": 0.5, "L3": 0.5])
        XCTAssertEqual(WordSelector.top(2, from: features(["L1", "L2", "L3"]),
                                        strategy: strategy, context: context), ["L1", "L2"])
    }
}
