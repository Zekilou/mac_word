import XCTest
@testable import WordRecitingApp

/// 一期-3：连续学习天数（纯函数）。
final class StreakCalculatorTests: XCTestCase {
    private let cal = Calendar.current

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func stat(_ date: String, events: Int = 0, reviews: Int = 0) -> DailyStat {
        DailyStat(date: date, known: 0, learning: 0, unknown: 0,
                  events: events, newWords: 0, reviews: reviews,
                  retention: nil, knownByBand: [:])
    }

    func testConsecutiveDaysEndingToday() {
        let stats = [stat("2026-09-07", events: 1),
                     stat("2026-09-08", events: 2),
                     stat("2026-09-09", events: 1)]
        XCTAssertEqual(StreakCalculator.current(stats, endingOn: day(2026, 9, 9), calendar: cal), 3)
    }

    /// 今天还没学习不算断签（从昨天起算）。
    func testTodayWithoutActivityKeepsStreak() {
        let stats = [stat("2026-09-07", events: 1),
                     stat("2026-09-08", events: 1),
                     stat("2026-09-09", events: 0)]
        XCTAssertEqual(StreakCalculator.current(stats, endingOn: day(2026, 9, 9), calendar: cal), 2)
    }

    func testGapBreaksStreak() {
        let stats = [stat("2026-09-05", events: 1),
                     stat("2026-09-08", events: 1),
                     stat("2026-09-09", events: 1)]
        XCTAssertEqual(StreakCalculator.current(stats, endingOn: day(2026, 9, 9), calendar: cal), 2)
    }

    func testNoActivityIsZero() {
        XCTAssertEqual(StreakCalculator.current([], endingOn: day(2026, 9, 9), calendar: cal), 0)
        let stale = [stat("2026-09-01", events: 3)]
        XCTAssertEqual(StreakCalculator.current(stale, endingOn: day(2026, 9, 9), calendar: cal), 0)
    }

    func testReviewOnlyDayCounts() {
        let stats = [stat("2026-09-08", reviews: 1),
                     stat("2026-09-09", events: 1)]
        XCTAssertEqual(StreakCalculator.current(stats, endingOn: day(2026, 9, 9), calendar: cal), 2)
    }
}
