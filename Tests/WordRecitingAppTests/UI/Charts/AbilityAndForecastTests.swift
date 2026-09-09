import XCTest
@testable import WordRecitingApp

/// 三期：能力画像（CEFR 映射）与负载预测（到期分布）。
final class AbilityAndForecastTests: XCTestCase {
    private let cal = Calendar.current

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private var now: Date { day(2026, 9, 9) }

    // MARK: - CEFR

    func testCEFRLevelMapping() {
        XCTAssertNil(CEFRMapper.progress(families: 499).current)
        XCTAssertEqual(CEFRMapper.progress(families: 500).current, .a1)
        XCTAssertEqual(CEFRMapper.progress(families: 1500).current, .a2)
        XCTAssertEqual(CEFRMapper.progress(families: 2500).current, .b1)
        XCTAssertEqual(CEFRMapper.progress(families: 4500).current, .b2)
        XCTAssertEqual(CEFRMapper.progress(families: 8000).current, .c1)
        XCTAssertEqual(CEFRMapper.progress(families: 10000).current, .c2)
        XCTAssertEqual(CEFRMapper.progress(families: 20000).current, .c2)
    }

    func testCEFRProgressMidLevel() {
        let p = CEFRMapper.progress(families: 1000)
        XCTAssertEqual(p.current, .a1)
        XCTAssertEqual(p.next, .a2)
        XCTAssertEqual(p.remainingFamilies, 500, accuracy: 0.0001)
        XCTAssertEqual(p.progressToNext, 0.5, accuracy: 0.0001)
    }

    func testCEFRProgressBelowA1() {
        let p = CEFRMapper.progress(families: 100)
        XCTAssertNil(p.current)
        XCTAssertEqual(p.next, .a1)
        XCTAssertEqual(p.remainingFamilies, 400, accuracy: 0.0001)
        XCTAssertEqual(p.progressToNext, 0.2, accuracy: 0.0001)
    }

    func testCEFRProgressTopLevel() {
        let p = CEFRMapper.progress(families: 12000)
        XCTAssertEqual(p.current, .c2)
        XCTAssertNil(p.next)
        XCTAssertEqual(p.remainingFamilies, 0, accuracy: 0.0001)
        XCTAssertEqual(p.progressToNext, 1, accuracy: 0.0001)
    }

    // MARK: - 负载预测

    func testForecastBucketsOverdueAndNewCardsIntoToday() {
        let forecast = ForecastBuilder.forecast(
            dueDates: [nil, now, day(2026, 9, 8), day(2026, 9, 10)],
            days: 5, now: now, calendar: cal)
        XCTAssertEqual(forecast.count, 5)
        XCTAssertEqual(forecast[0].due, 3)
        XCTAssertEqual(forecast[1].due, 1)
        XCTAssertEqual(forecast[0].date, "2026-09-09")
        XCTAssertEqual(forecast[1].date, "2026-09-10")
    }

    func testForecastSkipsBeyondHorizon() {
        let forecast = ForecastBuilder.forecast(
            dueDates: [day(2026, 12, 31)], days: 3, now: now, calendar: cal)
        XCTAssertEqual(forecast.reduce(0) { $0 + $1.due }, 0)
    }

    func testForecastTodayLoadAndPeak() {
        let forecast = ForecastBuilder.forecast(
            dueDates: [now, day(2026, 9, 11), day(2026, 9, 11), day(2026, 9, 11)],
            days: 5, now: now, calendar: cal)
        XCTAssertEqual(ForecastBuilder.todayLoad(forecast), 1)
        XCTAssertEqual(ForecastBuilder.peak(forecast)?.date, "2026-09-11")
    }

    func testForecastEmpty() {
        XCTAssertEqual(ForecastBuilder.todayLoad([]), 0)
        XCTAssertNil(ForecastBuilder.peak([]))
    }

    func testForecastPoints() {
        let forecast = ForecastBuilder.forecast(
            dueDates: [now, day(2026, 9, 11)], days: 3, now: now, calendar: cal)
        let points = ForecastBuilder.points(forecast)
        XCTAssertEqual(points.map(\.label), ["2026-09-09", "2026-09-10", "2026-09-11"])
        XCTAssertEqual(points.map(\.value), [1, 0, 1])
    }
}
