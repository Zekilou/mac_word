import XCTest
import SwiftUI
@testable import WordRecitingApp

/// 一期-2：图表数据整形（纯函数层，可单测）。
final class AnalyticsChartDataTests: XCTestCase {
    private let cal = Calendar.current

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func stat(_ date: String, known: Int, learning: Int, unknown: Int,
                      retention: Double? = nil, events: Int = 0, newWords: Int = 0,
                      reviews: Int = 0) -> DailyStat {
        DailyStat(date: date, known: known, learning: learning, unknown: unknown,
                  events: events, newWords: newWords, reviews: reviews,
                  retention: retention, knownByBand: [:])
    }

    // MARK: - DayKey

    func testDayKeyRoundTrip() {
        let key = DayKey.string(from: day(2026, 9, 9), calendar: cal)
        XCTAssertEqual(key, "2026-09-09")
        XCTAssertEqual(DayKey.date(from: key, calendar: cal).map { DayKey.string(from: $0, calendar: cal) }, key)
        XCTAssertNil(DayKey.date(from: "2026-09", calendar: cal))
    }

    // MARK: - 直方图

    func testHistogramBinsValues() {
        let bins = HistogramBuilder.bins(values: [0.1, 0.2, 0.9],
                                         lowerBound: 0, upperBound: 1, binCount: 2)
        XCTAssertEqual(bins.map(\.count), [2, 1])
        XCTAssertEqual(bins[0].lowerBound, 0, accuracy: 0.0001)
        XCTAssertEqual(bins[0].upperBound, 0.5, accuracy: 0.0001)
        XCTAssertEqual(bins[1].lowerBound, 0.5, accuracy: 0.0001)
        XCTAssertEqual(bins[1].upperBound, 1.0, accuracy: 0.0001)
    }

    func testHistogramPutsUpperBoundInLastBin() {
        let bins = HistogramBuilder.bins(values: [1.0, 0.999],
                                         lowerBound: 0, upperBound: 1, binCount: 4)
        XCTAssertEqual(bins.last?.count, 2)
    }

    func testHistogramIgnoresOutOfRange() {
        let bins = HistogramBuilder.bins(values: [-1, 2],
                                         lowerBound: 0, upperBound: 1, binCount: 2)
        XCTAssertEqual(bins.map(\.count), [0, 0])
    }

    func testHistogramEmptyOnInvalidRange() {
        XCTAssertTrue(HistogramBuilder.bins(values: [0.5], lowerBound: 0,
                                            upperBound: 0, binCount: 2).isEmpty)
        XCTAssertTrue(HistogramBuilder.bins(values: [0.5], lowerBound: 0,
                                            upperBound: 1, binCount: 0).isEmpty)
    }

    // MARK: - 热力图

    /// 2026-09-09 是周三；周一为一周起始 → 该周为 09-07(周一)…09-13(周日)。
    func testHeatmapGridLayout() throws {
        let cells = HeatmapBuilder.grid(values: ["2026-09-09": 5],
                                        endingOn: day(2026, 9, 9), weeks: 1, calendar: cal)
        XCTAssertEqual(cells.count, 7)
        let wed = try XCTUnwrap(cells.first { $0.id == "2026-09-09" })
        XCTAssertEqual(wed.weekday, 2)
        XCTAssertEqual(wed.weekIndex, 0)
        XCTAssertEqual(wed.value, 5)
        XCTAssertEqual(cells.first { $0.id == "2026-09-07" }?.weekday, 0)
        XCTAssertEqual(cells.first { $0.id == "2026-09-07" }?.value, 0)
        XCTAssertEqual(cells.last?.id, "2026-09-13")
    }

    func testHeatmapTwoWeeksOrderedByWeekIndex() {
        let cells = HeatmapBuilder.grid(values: [:], endingOn: day(2026, 9, 9),
                                        weeks: 2, calendar: cal)
        XCTAssertEqual(cells.count, 14)
        XCTAssertEqual(cells.map(\.weekIndex), Array(repeating: 0, count: 7) + Array(repeating: 1, count: 7))
        XCTAssertEqual(cells.first?.id, "2026-08-31")
    }

    // MARK: - 折线

    func testDailyStatPoints() {
        let stats = [stat("2026-09-08", known: 1, learning: 2, unknown: 3),
                     stat("2026-09-09", known: 4, learning: 5, unknown: 6)]
        let points = stats.points { Double($0.known) }
        XCTAssertEqual(points.map(\.label), ["2026-09-08", "2026-09-09"])
        XCTAssertEqual(points.map(\.value), [1, 4])
    }

    func testDailyStatPointsSkipsNil() {
        let stats = [stat("2026-09-08", known: 1, learning: 0, unknown: 0, retention: nil),
                     stat("2026-09-09", known: 1, learning: 0, unknown: 0, retention: 0.8)]
        let points = stats.points(ifPresent: { $0.retention })
        XCTAssertEqual(points.map(\.label), ["2026-09-09"])
        XCTAssertEqual(points.first?.value ?? 0, 0.8, accuracy: 0.0001)
    }

    // MARK: - 堆叠柱

    func testStackedTierSegments() {
        let segments = StackedBarBuilder.tierSegments([
            stat("2026-09-09", known: 3, learning: 2, unknown: 1)
        ])
        XCTAssertEqual(segments.map(\.series), [.known, .learning, .unknown])
        XCTAssertEqual(segments.map(\.value), [3, 2, 1])
        XCTAssertEqual(segments.map(\.category), ["2026-09-09", "2026-09-09", "2026-09-09"])
    }

    // MARK: - 系列颜色/标签合同

    func testChartSeriesMatchesWordMarkState() {
        XCTAssertEqual(ChartSeries.known.color, WordMarkState.known.color)
        XCTAssertEqual(ChartSeries.unknown.color, WordMarkState.unknown.color)
        XCTAssertEqual(ChartSeries.learning.color, WordMarkState.learning(0.5).color)
        XCTAssertEqual(ChartSeries.known.label, WordMarkState.known.label)
    }
}
