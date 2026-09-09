import XCTest
@testable import WordRecitingApp

/// 二期：记忆质量 / 学习行为的纯整形层。
final class AnalyticsBuildersTests: XCTestCase {
    private let cal = Calendar.current

    private func record(_ rating: Rating, elapsedDays: Double? = nil,
                        at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ReviewRecord {
        ReviewRecord(ratedAt: at, rating: rating.rawValue,
                     elapsedDays: elapsedDays, lastInterval: elapsedDays, factor: 2.5)
    }

    private func stat(_ date: String, newWords: Int = 0, reviews: Int = 0,
                      retention: Double? = nil) -> DailyStat {
        DailyStat(date: date, known: 0, learning: 0, unknown: 0,
                  events: 0, newWords: newWords, reviews: reviews,
                  retention: retention, knownByBand: [:])
    }

    // MARK: - 保留率

    func testTrueRetention() {
        let records = [record(.again), record(.hard), record(.good), record(.easy)]
        // hard 也算未通过（只有 good/easy 通过）
        XCTAssertEqual(RetentionBuilder.trueRetention(records) ?? 0, 0.5, accuracy: 0.0001)
    }

    func testTrueRetentionNilWhenEmpty() {
        XCTAssertNil(RetentionBuilder.trueRetention([]))
    }

    func testRatingDistributionFixedOrderAndZeroCounts() {
        let slices = RetentionBuilder.ratingDistribution([record(.good), record(.good), record(.easy)])
        XCTAssertEqual(slices.map(\.rating), [1, 2, 3, 4])
        XCTAssertEqual(slices.map(\.count), [0, 0, 2, 1])
        XCTAssertEqual(slices.map(\.label), ["不认识", "困难", "记得", "简单"])
    }

    // MARK: - 遗忘曲线

    func testForgettingCurveBinsByElapsedDays() {
        let records = [record(.again, elapsedDays: 0.5),
                       record(.good, elapsedDays: 0.5),
                       record(.good, elapsedDays: 2),
                       record(.again, elapsedDays: 10)]
        let points = RetentionBuilder.forgettingCurve(records)
        XCTAssertEqual(points.map(\.label), ["0–1天", "1–3天", "7–14天"])
        XCTAssertEqual(points[0].value, 0.5, accuracy: 0.0001)
        XCTAssertEqual(points[1].value, 1.0, accuracy: 0.0001)
        XCTAssertEqual(points[2].value, 0.0, accuracy: 0.0001)
    }

    func testForgettingCurveSkipsEmptyAndNilElapsed() {
        let records = [record(.good, elapsedDays: nil), record(.good, elapsedDays: 2)]
        let points = RetentionBuilder.forgettingCurve(records)
        XCTAssertEqual(points.map(\.label), ["1–3天"])
    }

    // MARK: - 学习行为

    func testHeatmapValuesByMode() {
        let stats = [stat("2026-09-08", newWords: 3, reviews: 5, retention: 0.8),
                     stat("2026-09-09", newWords: 1, reviews: 0, retention: nil)]
        XCTAssertEqual(BehaviorBuilder.heatmapValues(stats, mode: .reviews),
                       ["2026-09-08": 5, "2026-09-09": 0])
        XCTAssertEqual(BehaviorBuilder.heatmapValues(stats, mode: .newWords),
                       ["2026-09-08": 3, "2026-09-09": 1])
        XCTAssertEqual(BehaviorBuilder.heatmapValues(stats, mode: .retention),
                       ["2026-09-08": 80])
    }

    func testHourDistribution() {
        let morning = cal.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 9))!
        let night = cal.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 21))!
        let bins = BehaviorBuilder.hourDistribution([
            ReviewRecord(ratedAt: morning, rating: 3, elapsedDays: nil, lastInterval: nil, factor: nil),
            ReviewRecord(ratedAt: morning, rating: 4, elapsedDays: nil, lastInterval: nil, factor: nil),
            ReviewRecord(ratedAt: night, rating: 1, elapsedDays: nil, lastInterval: nil, factor: nil)
        ], calendar: cal)
        XCTAssertEqual(bins.count, 24)
        XCTAssertEqual(bins[9].count, 2)
        XCTAssertEqual(bins[21].count, 1)
        XCTAssertEqual(bins.reduce(0) { $0 + $1.count }, 3)
    }

    // MARK: - 顽固词平滑失败率

    func testSmoothedFailureRate() {
        XCTAssertEqual(WeakLemmaStat(lemmaId: "L", text: "a", definition: nil,
                                     reviewCount: 0, againCount: 0)
            .smoothedFailureRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(WeakLemmaStat(lemmaId: "L", text: "a", definition: nil,
                                     reviewCount: 10, againCount: 5)
            .smoothedFailureRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(WeakLemmaStat(lemmaId: "L", text: "a", definition: nil,
                                     reviewCount: 8, againCount: 0)
            .smoothedFailureRate, 0.1, accuracy: 0.0001)
    }
}
