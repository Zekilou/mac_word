import SwiftUI
import Charts

/// 图表组件层（薄壳）：只负责把整形好的数据画出来，不做取数 / 分桶 / 排序。
/// @ai: 新增图表一律进本文件，颜色只从 `ChartSeries` / `ChartTint` 取。

// MARK: - 外壳

/// 图表卡片：标题 + 副标题 + 内容，统一分析页的视觉节奏。
struct ChartCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5), lineWidth: 1))
    }
}

/// 图表空态。
struct ChartEmptyState: View {
    var text: String = "暂无数据"
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }
}

/// 系列图例（颜色 / 标签来自 `ChartSeries`）。
struct ChartSeriesLegend: View {
    let series: [ChartSeries]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(series) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 8, height: 8)
                    Text(item.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 折线

/// 折线图（可选目标带，如保留率 80–90%）。
struct AnalyticsLineChart: View {
    let points: [ChartPoint]
    var targetBand: ClosedRange<Double>? = nil
    var valueFormat: (Double) -> String = { String(format: "%.0f", $0) }
    var tint: ChartTint = .accent
    var height: CGFloat = 160

    var body: some View {
        if points.isEmpty {
            ChartEmptyState()
        } else {
            Chart {
                if let targetBand {
                    RectangleMark(yStart: .value("下限", targetBand.lowerBound),
                                  yEnd: .value("上限", targetBand.upperBound))
                        .foregroundStyle(tint.color.opacity(0.10))
                }
                ForEach(points) { point in
                    LineMark(x: .value("日期", point.label),
                             y: .value("值", point.value))
                        .foregroundStyle(tint.color)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("日期", point.label),
                              y: .value("值", point.value))
                        .foregroundStyle(tint.color)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(valueFormat(v)).font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - 柱

/// 柱状图（可堆叠；堆叠顺序由传入顺序决定）。
struct AnalyticsBarChart: View {
    let segments: [ChartSegment]
    var stacked: Bool = true
    var valueFormat: (Double) -> String = { String(format: "%.0f", $0) }
    var height: CGFloat = 160

    var body: some View {
        if segments.isEmpty {
            ChartEmptyState()
        } else {
            Chart(segments) { segment in
                if stacked {
                    BarMark(x: .value("日期", segment.category),
                            y: .value("数量", segment.value))
                        .foregroundStyle(segment.series.color)
                } else {
                    BarMark(x: .value("日期", segment.category),
                            y: .value("数量", segment.value))
                        .foregroundStyle(segment.series.color)
                        .position(by: .value("系列", segment.series.label))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(valueFormat(v)).font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - 单系列柱

/// 单系列柱状图（复习量 / 时段分布等）。
struct AnalyticsSimpleBarChart: View {
    let points: [ChartPoint]
    var tint: ChartTint = .accent
    var valueFormat: (Double) -> String = { String(format: "%.0f", $0) }
    var height: CGFloat = 140

    var body: some View {
        if points.isEmpty {
            ChartEmptyState()
        } else {
            Chart(points) { point in
                BarMark(x: .value("标签", point.label), y: .value("值", point.value))
                    .foregroundStyle(tint.color)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(valueFormat(v)).font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - 直方图

/// 直方图（区间分布，如复习间隔 / 难度因子）。
struct AnalyticsHistogram: View {
    let bins: [ChartBin]
    var xLabel: (ChartBin) -> String = { String(format: "%.1f", $0.lowerBound) }
    var tint: ChartTint = .blue
    var height: CGFloat = 140

    var body: some View {
        if bins.isEmpty {
            ChartEmptyState()
        } else {
            Chart(bins) { bin in
                BarMark(x: .value("区间", xLabel(bin)), y: .value("数量", bin.count))
                    .foregroundStyle(tint.color.opacity(0.85))
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)").font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - 热力图

/// 日历热力图（手绘网格；周一在上的 7 行 × N 周）。
struct AnalyticsHeatmap: View {
    let cells: [HeatmapCell]
    let weeks: Int
    var tint: ChartTint = .green
    var valueFormat: (Double) -> String = { String(format: "%.0f", $0) }
    var cellSize: CGFloat = 12

    private var maxValue: Double { max(cells.map(\.value).max() ?? 0, 1) }
    private let weekdayLabels = ["一", "", "三", "", "五", "", "日"]

    private var columns: [[HeatmapCell]] {
        (0..<max(weeks, 0)).map { week in
            cells.filter { $0.weekIndex == week }.sorted { $0.weekday < $1.weekday }
        }
    }

    private func opacity(_ value: Double) -> Double {
        value <= 0 ? 0 : 0.25 + 0.75 * min(value / maxValue, 1)
    }

    var body: some View {
        if cells.isEmpty {
            ChartEmptyState()
        } else {
            HStack(alignment: .top, spacing: 3) {
                VStack(spacing: 3) {
                    ForEach(weekdayLabels.indices, id: \.self) { index in
                        Text(weekdayLabels[index])
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, height: cellSize)
                    }
                }
                ForEach(columns.indices, id: \.self) { index in
                    VStack(spacing: 3) {
                        ForEach(columns[index]) { cell in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cell.value <= 0
                                      ? Color.secondary.opacity(0.08)
                                      : tint.color.opacity(opacity(cell.value)))
                                .frame(width: cellSize, height: cellSize)
                                .help("\(cell.id)：\(valueFormat(cell.value))")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Sparkline

/// 迷你折线（首页 / 卡片内嵌趋势）。
struct AnalyticsSparkline: View {
    let points: [ChartPoint]
    var tint: ChartTint = .accent
    var height: CGFloat = 28

    var body: some View {
        if points.count < 2 {
            Color.clear.frame(height: height)
        } else {
            Chart(points) { point in
                LineMark(x: .value("日期", point.label), y: .value("值", point.value))
                    .foregroundStyle(tint.color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: height)
        }
    }
}

// MARK: - 等级条

/// 水平分段条（等级 / 覆盖度；占比 = value / total）。
struct AnalyticsLevelBar: View {
    let segments: [LevelSegment]
    let total: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.tint.color)
                        .frame(width: total > 0
                               ? max(0, geo.size.width * segment.value / total)
                               : 0)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.5), lineWidth: 1))
    }
}
