import Foundation

/// 记忆质量 / 学习行为的纯整形层（不依赖数据库与视图，可单测）。

// MARK: - 记忆质量

enum RetentionBuilder {

    /// 评分分布的一段（固定四档顺序）。
    struct RatingSlice: Identifiable, Equatable, Sendable {
        var id: Int { rating }
        let rating: Int
        let label: String
        let count: Int
        let tint: ChartTint
    }

    /// 遗忘曲线的一个桶（`lower ≤ days < upper`）。
    struct CurveBin: Equatable, Sendable {
        let lower: Double
        let upper: Double
        let label: String
    }

    /// 默认分桶：0–1 / 1–3 / 3–7 / 7–14 / 14–30 / 30–60 / 60–120 / 120+ 天。
    static let forgettingCurveBins: [CurveBin] = [
        CurveBin(lower: 0, upper: 1, label: "0–1天"),
        CurveBin(lower: 1, upper: 3, label: "1–3天"),
        CurveBin(lower: 3, upper: 7, label: "3–7天"),
        CurveBin(lower: 7, upper: 14, label: "7–14天"),
        CurveBin(lower: 14, upper: 30, label: "14–30天"),
        CurveBin(lower: 30, upper: 60, label: "30–60天"),
        CurveBin(lower: 60, upper: 120, label: "60–120天"),
        CurveBin(lower: 120, upper: .infinity, label: "120天+")
    ]

    /// 真实保留率：通过 = good / easy（rating ≥ 3）；无复习返回 nil。
    static func trueRetention(_ records: [ReviewRecord]) -> Double? {
        guard !records.isEmpty else { return nil }
        let passed = records.filter { $0.rating >= Rating.good.rawValue }.count
        return Double(passed) / Double(records.count)
    }

    /// 评分分布（again / hard / good / easy 固定顺序，含 0 计数）。
    static func ratingDistribution(_ records: [ReviewRecord]) -> [RatingSlice] {
        Rating.allCases.map { rating in
            RatingSlice(rating: rating.rawValue,
                        label: label(for: rating),
                        count: records.filter { $0.rating == rating.rawValue }.count,
                        tint: tint(for: rating))
        }
    }

    /// 经验遗忘曲线：按「距上次复习天数」分桶的保留率（空桶与无 elapsed 的记录跳过）。
    static func forgettingCurve(_ records: [ReviewRecord],
                                bins: [CurveBin] = forgettingCurveBins) -> [ChartPoint] {
        bins.compactMap { bin in
            let inBin = records.filter { record in
                guard let days = record.elapsedDays else { return false }
                return days >= bin.lower && days < bin.upper
            }
            guard !inBin.isEmpty else { return nil }
            let passed = inBin.filter { $0.rating >= Rating.good.rawValue }.count
            return ChartPoint(label: bin.label, value: Double(passed) / Double(inBin.count))
        }
    }

    static func label(for rating: Rating) -> String {
        switch rating {
        case .again: return "不认识"
        case .hard: return "困难"
        case .good: return "记得"
        case .easy: return "简单"
        }
    }

    static func tint(for rating: Rating) -> ChartTint {
        switch rating {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }
}

// MARK: - 学习行为

/// 日历热力图的取值模式。
enum HeatmapMode: String, CaseIterable, Identifiable, Sendable {
    case reviews
    case newWords
    case retention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reviews: return "复习量"
        case .newWords: return "新词"
        case .retention: return "保留率"
        }
    }
}

enum BehaviorBuilder {

    /// 热力图取值（保留率模式只含有复习的日）。
    static func heatmapValues(_ stats: [DailyStat], mode: HeatmapMode) -> [String: Double] {
        var result: [String: Double] = [:]
        for stat in stats {
            switch mode {
            case .reviews: result[stat.date] = Double(stat.reviews)
            case .newWords: result[stat.date] = Double(stat.newWords)
            case .retention:
                if let retention = stat.retention { result[stat.date] = retention * 100 }
            }
        }
        return result
    }

    /// 时段分布（0–23 点，24 个桶）。
    static func hourDistribution(_ records: [ReviewRecord],
                                 calendar: Calendar = .current) -> [ChartBin] {
        var counts = Array(repeating: 0, count: 24)
        for record in records {
            let hour = calendar.component(.hour, from: record.ratedAt)
            if (0..<24).contains(hour) { counts[hour] += 1 }
        }
        return (0..<24).map { hour in
            ChartBin(id: hour, lowerBound: Double(hour), upperBound: Double(hour + 1),
                     count: counts[hour])
        }
    }
}
