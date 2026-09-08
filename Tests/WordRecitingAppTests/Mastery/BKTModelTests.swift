import XCTest
@testable import WordRecitingApp

final class BKTModelTests: XCTestCase {

    // MARK: - 先验

    func testPriorDecreasesWithBand() {
        let p1 = BKTModel.prior(band: 1)
        let p10 = BKTModel.prior(band: 10)
        let p25 = BKTModel.prior(band: 25)
        XCTAssertEqual(p1, 0.90, accuracy: 0.0001)
        XCTAssertEqual(p25, 0.10, accuracy: 0.0001)
        XCTAssertGreaterThan(p1, p10)
        XCTAssertGreaterThan(p10, p25)
    }

    func testPriorFallsBackWhenBandMissing() {
        XCTAssertEqual(BKTModel.prior(band: nil),
                       BKTParameters.default.fallbackPrior, accuracy: 0.0001)
    }

    func testPriorClampsOutOfRangeBand() {
        XCTAssertEqual(BKTModel.prior(band: 0), BKTModel.prior(band: 1), accuracy: 0.0001)
        XCTAssertEqual(BKTModel.prior(band: 99), BKTModel.prior(band: 25), accuracy: 0.0001)
    }

    // MARK: - 发射模型

    func testObservationDirections() {
        let known = BKTModel.observation(for: .markKnown)
        XCTAssertGreaterThan(known.likelihoodIfKnown, known.likelihoodIfUnknown)
        let unknown = BKTModel.observation(for: .markUnknown)
        XCTAssertGreaterThan(unknown.likelihoodIfUnknown, unknown.likelihoodIfKnown)
        let quizCorrect = BKTModel.observation(for: .quizCorrect)
        XCTAssertGreaterThan(quizCorrect.likelihoodIfKnown, quizCorrect.likelihoodIfUnknown)
        let seen = BKTModel.observation(for: .seen)
        XCTAssertEqual(seen.likelihoodIfKnown, 0.5, accuracy: 0.0001)
        XCTAssertEqual(seen.likelihoodIfUnknown, 0.5, accuracy: 0.0001)
    }

    // MARK: - 更新

    func testMarkKnownRaisesAndMarkUnknownLowers() {
        let start = 0.5
        let up = BKTModel.update(belief: start, kind: .markKnown,
                                 trust: 1.0, distinctRegions: 1)
        let down = BKTModel.update(belief: start, kind: .markUnknown,
                                   trust: 1.0, distinctRegions: 1)
        XCTAssertGreaterThan(up, start)
        XCTAssertLessThan(down, start)
    }

    /// trust = 0 → 无观察信息，后验 = 先验，但仍发生学习转移。
    func testZeroTrustOnlyAppliesLearning() {
        let start = 0.4
        let after = BKTModel.update(belief: start, kind: .markUnknown,
                                    trust: 0, distinctRegions: 1)
        let expected = start + (1 - start) * BKTModel.learnRate(distinctRegions: 1)
        XCTAssertEqual(after, expected, accuracy: 0.0001)
    }

    func testSeenAppliesLearningWithoutObservation() {
        let start = 0.3
        let after = BKTModel.update(belief: start, kind: .seen,
                                    trust: 0, distinctRegions: 1)
        XCTAssertGreaterThan(after, start)
    }

    func testLearnRateGrowsWithContextDiversityAndCaps() {
        let one = BKTModel.learnRate(distinctRegions: 1)
        let three = BKTModel.learnRate(distinctRegions: 3)
        let huge = BKTModel.learnRate(distinctRegions: 999)
        XCTAssertGreaterThan(three, one)
        XCTAssertEqual(huge, BKTModel.learnRate(distinctRegions: BKTParameters.default.cdCap),
                       accuracy: 0.0001)
    }

    // MARK: - 重放

    func testReplayAccumulatesEvidence() {
        let up = BKTModel.replay(
            events: [(kind: .markKnown, trust: 1.0), (kind: .markKnown, trust: 1.0)],
            prior: 0.3, distinctRegions: 1)
        let down = BKTModel.replay(
            events: [(kind: .markUnknown, trust: 1.0), (kind: .markUnknown, trust: 1.0)],
            prior: 0.3, distinctRegions: 1)
        XCTAssertGreaterThan(up, down)
        XCTAssertGreaterThan(up, 0.3)
        XCTAssertLessThan(down, 0.3)
    }

    func testReplayEmptyReturnsPrior() {
        let prior = 0.42
        XCTAssertEqual(BKTModel.replay(events: [], prior: prior, distinctRegions: 1),
                       prior, accuracy: 0.0001)
    }

    func testBeliefStaysInOpenUnitInterval() {
        var belief = 0.5
        for _ in 0..<300 {
            belief = BKTModel.update(belief: belief, kind: .markKnown,
                                     trust: 1.0, distinctRegions: 5)
        }
        XCTAssertLessThan(belief, 1.0)
        XCTAssertGreaterThan(belief, 0.0)

        for _ in 0..<300 {
            belief = BKTModel.update(belief: belief, kind: .markUnknown,
                                     trust: 1.0, distinctRegions: 5)
        }
        XCTAssertGreaterThan(belief, 0.0)
        XCTAssertLessThan(belief, 1.0)
    }

    func testParametersAreVersioned() {
        XCTAssertEqual(BKTParameters.default.version, "bkt-1")
    }
}
