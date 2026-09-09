import SwiftUI

/// 图表数据整形层：纯函数 / 纯值类型，不依赖数据库与视图，便于单测。
/// @ai: 各页只负责「取数 → 整形 → 交给图表组件」，禁止在视图里做分桶 / 补日 / 排序。

// MARK: - 系列

/// 图表系列（颜色 / 标签唯一来源 `WordMarkState`，禁止各图自定义色）。
enum ChartSeries: String, Sendable, CaseIterable, Identifiable {
    case known
    case learning
    case unknown
    case seen
    case pending

    var id: String { rawValue }

    var state: WordMarkState {
        switch self {
        case .known: return .known
        case .learning: return .learning(0.5)
        case .unknown: return .unknown
        case .seen: return .seen
        case .pending: return .pending
        }
    }

    var label: String { state.label }
    var color: Color { state.color }
}

// MARK: - 值类型

/// 折线 / sparkline 的一个点。
struct ChartPoint: Identifiable, Equatable, Sendable {
    var id: String { label }
    /// x 轴标签（通常是日期键）。
    let label: String
    let value: Double
}

/// 堆叠柱的一段。
struct ChartSegment: Identifiable, Equatable, Sendable {
    var id: String { "\(category)|\(series.rawValue)" }
    /// x 轴分类（通常是日期键）。
    let category: String
    let series: ChartSeries
    let value: Double
}

/// 直方图的一个桶（半开区间 [lowerBound, upperBound)，最后一桶含上界）。
struct ChartBin: Identifiable, Equatable, Sendable {
    let id: Int
    let lowerBound: Double
    let upperBound: Double
    let count: Int
}

/// 热力图的一格。
struct HeatmapCell: Identifiable, Equatable, Sendable {
    /// 日期键 `yyyy-MM-dd`。
    let id: String
    /// 第几列（0 = 最早的一周）。
    let weekIndex: Int
    /// 周一 = 0 … 周日 = 6。
    let weekday: Int
    let value: Double
}

/// 非档位语义的中性色板（等级条 / 覆盖度等）。
enum ChartTint: String, Sendable, CaseIterable {
    case accent
    case green
    case orange
    case red
    case blue
    case gray

    var color: Color {
        switch self {
        case .accent: return .accentColor
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .blue: return .blue
        case .gray: return .gray
        }
    }
}

/// 等级条 / 覆盖条的一段（占比 = value / total）。
struct LevelSegment: Identifiable, Equatable, Sendable {
    var id: String { label }
    let label: String
    let value: Double
    let tint: ChartTint
}

// MARK: - 整形器

enum HistogramBuilder {
    /// 把数值分到 `[lowerBound, upperBound]` 的等宽桶里；越界值忽略，上界计入最后一桶。
    static func bins(values: [Double], lowerBound: Double, upperBound: Double,
                     binCount: Int) -> [ChartBin] {
        guard binCount > 0, upperBound > lowerBound else { return [] }
        let width = (upperBound - lowerBound) / Double(binCount)
        var counts = Array(repeating: 0, count: binCount)
        for value in values {
            guard value >= lowerBound, value <= upperBound else { continue }
            var index = Int((value - lowerBound) / width)
            if index >= binCount { index = binCount - 1 }
            if index < 0 { index = 0 }
            counts[index] += 1
        }
        return (0..<binCount).map { index in
            let low = lowerBound + Double(index) * width
            return ChartBin(id: index, lowerBound: low, upperBound: low + width, count: counts[index])
        }
    }
}

enum HeatmapBuilder {
    /// 把「日期键 → 值」铺成 `weeks × 7` 的格子（周一为一周起始，最后一周包含 `endingOn`）。
    /// 缺日补 0；返回顺序为「周序 × 星期序」。
    static func grid(values: [String: Double], endingOn: Date, weeks: Int,
                     calendar: Calendar = .current) -> [HeatmapCell] {
        guard weeks > 0 else { return [] }
        var cal = calendar
        cal.firstWeekday = 2
        let end = cal.startOfDay(for: endingOn)
        let weekdayComponent = cal.component(.weekday, from: end)
        let weekdayIndex = (weekdayComponent - cal.firstWeekday + 7) % 7
        guard let lastDay = cal.date(byAdding: .day, value: 6 - weekdayIndex, to: end),
              let startDay = cal.date(byAdding: .day, value: -(weeks * 7 - 1), to: lastDay)
        else { return [] }
        return (0..<(weeks * 7)).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: offset, to: startDay) else { return nil }
            let key = DayKey.string(from: date, calendar: cal)
            return HeatmapCell(id: key, weekIndex: offset / 7, weekday: offset % 7,
                               value: values[key] ?? 0)
        }
    }
}

enum StackedBarBuilder {
    /// 每日「已会 / 学习中 / 不会」堆叠段（系列顺序固定）。
    static func tierSegments(_ stats: [DailyStat]) -> [ChartSegment] {
        stats.flatMap { stat in
            [
                ChartSegment(category: stat.date, series: .known, value: Double(stat.known)),
                ChartSegment(category: stat.date, series: .learning, value: Double(stat.learning)),
                ChartSegment(category: stat.date, series: .unknown, value: Double(stat.unknown))
            ]
        }
    }
}

extension Array where Element == DailyStat {
    /// 折线点：label = 日期键。
    func points(_ value: (DailyStat) -> Double) -> [ChartPoint] {
        map { ChartPoint(label: $0.date, value: value($0)) }
    }

    /// 折线点：`value` 返回 nil 的点跳过（如无复习日的保留率）。
    func points(ifPresent value: (DailyStat) -> Double?) -> [ChartPoint] {
        compactMap { stat in
            guard let v = value(stat) else { return nil }
            return ChartPoint(label: stat.date, value: v)
        }
    }
}
