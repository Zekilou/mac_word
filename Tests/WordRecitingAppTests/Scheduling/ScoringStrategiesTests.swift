import XCTest
@testable import WordRecitingApp

final class ScoringStrategiesTests: XCTestCase {

    private func features(_ id: EntityID, belief: Double? = nil, band: Int? = nil) -> WordFeatures {
        WordFeatures(lemmaId: id, belief: belief, band: band, rank: nil,
                     eventCount: 0, contextCount: 0, lastEventAt: nil, card: nil)
    }

    private func context(bandWindow: ClosedRange<Int>? = nil) -> ScoringContext {
        ScoringContext(purpose: .articleTargets, now: Date(), bandWindow: bandWindow)
    }

    // MARK: - RandomScoring

    func testRandomScoringStaysInUnitRange() {
        let strategy = RandomScoring()
        for _ in 0..<50 {
            let value = strategy.score(features("L1"), context: context())
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    // MARK: - CriticalWordScoring

    func testCriticalScoringPeaksAtHalf() {
        let strategy = CriticalWordScoring()
        XCTAssertEqual(strategy.score(features("L1", belief: 0.5), context: context()),
                       1.0, accuracy: 0.0001)
    }

    func testCriticalScoringFallsOffAtExtremes() {
        let strategy = CriticalWordScoring()
        XCTAssertEqual(strategy.score(features("L1", belief: 0.0), context: context()),
                       0.0, accuracy: 0.0001)
        XCTAssertEqual(strategy.score(features("L1", belief: 1.0), context: context()),
                       0.0, accuracy: 0.0001)
        XCTAssertEqual(strategy.score(features("L1", belief: 0.25), context: context()),
                       0.5, accuracy: 0.0001)
    }

    func testCriticalScoringWithoutBeliefIsNeutral() {
        let strategy = CriticalWordScoring()
        XCTAssertEqual(strategy.score(features("L1", belief: nil), context: context()),
                       0.5, accuracy: 0.0001)
    }

    // MARK: - FrequencyTierScoring

    func testFrequencyTierPrefersHighFrequencyBands() {
        let strategy = FrequencyTierScoring()
        XCTAssertEqual(strategy.score(features("L1", band: 1), context: context()),
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(strategy.score(features("L1", band: 25), context: context()),
                       0.0, accuracy: 0.0001)
        XCTAssertEqual(strategy.score(features("L1", band: 3), context: context()),
                       1.0 - 2.0 / 24.0, accuracy: 0.0001)
    }

    func testFrequencyTierRespectsBandWindow() {
        let strategy = FrequencyTierScoring()
        let window = context(bandWindow: 1...3)
        XCTAssertGreaterThan(strategy.score(features("L1", band: 3), context: window), 0)
        XCTAssertEqual(strategy.score(features("L1", band: 5), context: window), 0,
                       "窗口外直接 0")
    }

    func testFrequencyTierWithoutBandIsZero() {
        let strategy = FrequencyTierScoring()
        XCTAssertEqual(strategy.score(features("L1", band: nil), context: context()), 0)
    }

    // MARK: - 注册表

    func testScoringRegistryCoversAllIDs() {
        for id in WordScoringID.allCases {
            XCTAssertEqual(SchedulingRegistry.scoring(id).id, id)
        }
    }
}
