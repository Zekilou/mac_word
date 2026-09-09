import XCTest
@testable import WordRecitingApp

final class FrequencyAwareIntervalPolicyTests: XCTestCase {
    private let policy = FrequencyAwareIntervalPolicy()

    private func features(belief: Double? = nil, band: Int? = nil) -> WordFeatures {
        WordFeatures(lemmaId: "L1", belief: belief, band: band, rank: nil,
                     eventCount: 0, contextCount: 0, lastEventAt: nil, card: nil)
    }

    private var baseState: ScheduleStateComponent {
        ScheduleStateComponent(
            entityId: "C1", stability: nil, difficulty: 2.5, dueAt: nil,
            intervalDays: 4, reps: 2, lapses: 0,
            lastRating: nil, lastReviewedAt: nil,
            schedulerId: "sm-2", queue: "review", customDataJson: nil)
    }

    private func interval(_ f: WordFeatures, _ rating: Rating = .good) -> Double {
        policy.next(state: baseState, rating: rating, features: f,
                    now: Date(timeIntervalSince1970: 1_000_000)).intervalDays ?? 0
    }

    /// SM-2 基线：4 天 × factor 2.5 = 10 天。
    private let baseline = 10.0

    func testHighFrequencyBandExtendsInterval() {
        XCTAssertEqual(interval(features(band: 1)), baseline * 1.3, accuracy: 0.0001)
        XCTAssertEqual(interval(features(band: 3)), baseline * 1.3, accuracy: 0.0001)
    }

    func testLowFrequencyBandShortensInterval() {
        XCTAssertEqual(interval(features(band: 10)), baseline * 0.8, accuracy: 0.0001)
        XCTAssertEqual(interval(features(band: 25)), baseline * 0.8, accuracy: 0.0001)
    }

    func testMidBandIsUnchanged() {
        XCTAssertEqual(interval(features(band: 5)), baseline, accuracy: 0.0001)
    }

    func testHighConfidenceExtendsInterval() {
        XCTAssertEqual(interval(features(belief: 0.95)), baseline * 1.5, accuracy: 0.0001)
    }

    func testHighConfidenceDoesNotApplyToHardRating() {
        XCTAssertEqual(interval(features(belief: 0.95), .hard), 4 * 2.35, accuracy: 0.0001)
    }

    func testMultipliersCompose() {
        XCTAssertEqual(interval(features(belief: 0.95, band: 1)),
                       baseline * 1.95, accuracy: 0.0001)
    }

    func testNoFrequencyAndNoBeliefFallsBackToBase() {
        XCTAssertEqual(interval(features()), baseline, accuracy: 0.0001)
    }

    func testAgainIsNeverModulated() {
        let result = policy.next(state: baseState, rating: .again,
                                 features: features(belief: 0.99, band: 1),
                                 now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(result.intervalDays ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(result.lapses, 1)
    }

    func testSchedulerIdIsWritten() {
        let result = policy.next(state: baseState, rating: .good,
                                 features: features(band: 1),
                                 now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(result.schedulerId, "sm-2-frequency")
    }

    // MARK: - 注册表

    func testReviewRegistryCoversImplementedIDs() {
        XCTAssertEqual(SchedulingRegistry.reviewPolicy(.sm2).id, .sm2)
        XCTAssertEqual(SchedulingRegistry.reviewPolicy(.sm2Frequency).id, .sm2Frequency)
        // FSRS 尚未实现：按设计回退 SM-2（写入的 scheduler_id 也是 sm-2）。
        XCTAssertEqual(SchedulingRegistry.reviewPolicy(.fsrsV4).id, .sm2)
    }
}
