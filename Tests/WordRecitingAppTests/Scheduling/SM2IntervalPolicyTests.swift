import XCTest
@testable import WordRecitingApp

final class SM2IntervalPolicyTests: XCTestCase {
    private let policy = SM2IntervalPolicy()

    private func features() -> WordFeatures {
        WordFeatures(lemmaId: "L1", belief: nil, band: nil, rank: nil,
                     eventCount: 0, contextCount: 0, lastEventAt: nil, card: nil)
    }

    private func state(reps: Int?, difficulty: Double?,
                       intervalDays: Double?) -> ScheduleStateComponent {
        ScheduleStateComponent(
            entityId: "C1", stability: nil, difficulty: difficulty, dueAt: nil,
            intervalDays: intervalDays, reps: reps, lapses: 0,
            lastRating: nil, lastReviewedAt: nil,
            schedulerId: "sm-2", queue: "new", customDataJson: nil)
    }

    private func next(_ s: ScheduleStateComponent, _ rating: Rating,
                      now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ScheduleStateComponent {
        policy.next(state: s, rating: rating, features: features(), now: now)
    }

    // MARK: - 首次复习

    func testFirstReviewIntervals() {
        let fresh = state(reps: nil, difficulty: nil, intervalDays: nil)
        XCTAssertEqual(next(fresh, .again).intervalDays ?? 0, 10.0 / 1440.0, accuracy: 0.000001)
        XCTAssertEqual(next(fresh, .hard).intervalDays ?? 0, 1, accuracy: 0.000001)
        XCTAssertEqual(next(fresh, .good).intervalDays ?? 0, 3, accuracy: 0.000001)
        XCTAssertEqual(next(fresh, .easy).intervalDays ?? 0, 7, accuracy: 0.000001)
    }

    // MARK: - 后续复习

    func testAgainResetsIntervalAndDropsFactor() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 10), .again)
        XCTAssertEqual(result.intervalDays ?? 0, 1, accuracy: 0.000001)
        XCTAssertEqual(result.lapses, 1)
        XCTAssertEqual(result.difficulty ?? 0, 2.3, accuracy: 0.0001)
    }

    func testFactorFloorIsOnePointThree() {
        let result = next(state(reps: 5, difficulty: 1.35, intervalDays: 5), .again)
        XCTAssertEqual(result.difficulty ?? 0, 1.3, accuracy: 0.0001)
    }

    func testGoodMultipliesByFactor() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .good)
        XCTAssertEqual(result.intervalDays ?? 0, 10, accuracy: 0.0001)
    }

    func testHardUsesReducedFactor() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .hard)
        XCTAssertEqual(result.intervalDays ?? 0, 4 * 2.35, accuracy: 0.0001)
    }

    func testEasyAddsThirtyPercent() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .easy)
        XCTAssertEqual(result.intervalDays ?? 0, 4 * 2.5 * 1.3, accuracy: 0.0001)
    }

    // MARK: - 元数据

    func testQueueFollowsInterval() {
        XCTAssertEqual(next(state(reps: nil, difficulty: nil, intervalDays: nil), .again).queue,
                       "learning")
        XCTAssertEqual(next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .good).queue,
                       "review")
    }

    func testSchedulerIdAndDueAt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .good, now: now)
        XCTAssertEqual(result.schedulerId, "sm-2")
        XCTAssertEqual(result.dueAt ?? .distantPast, now.addingTimeInterval(10 * 86400))
    }

    func testRepsAndLastRatingAreUpdated() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .good)
        XCTAssertEqual(result.reps, 3)
        XCTAssertEqual(result.lastRating, Rating.good.rawValue)
    }
}
