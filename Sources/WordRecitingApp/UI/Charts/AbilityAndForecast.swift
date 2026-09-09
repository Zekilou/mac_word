import Foundation

// MARK: - 能力画像：CEFR 映射

/// CEFR 等级（按词族数映射；阈值是常用参考值，不是硬标准）。
enum CEFRLevel: String, CaseIterable, Identifiable, Sendable {
    case a1
    case a2
    case b1
    case b2
    case c1
    case c2

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// 进入该等级所需词族数下限。
    var minFamilies: Double {
        switch self {
        case .a1: return 500
        case .a2: return 1_500
        case .b1: return 2_500
        case .b2: return 4_500
        case .c1: return 8_000
        case .c2: return 10_000
        }
    }

    var title: String {
        switch self {
        case .a1: return "入门"
        case .a2: return "初级"
        case .b1: return "中级"
        case .b2: return "中高级"
        case .c1: return "高级"
        case .c2: return "精通"
        }
    }
}

/// CEFR 进度：当前等级 / 下一等级 / 还差多少词族 / 到下一等级的进度。
struct CEFRProgress: Equatable, Sendable {
    let current: CEFRLevel?
    let next: CEFRLevel?
    let remainingFamilies: Double
    let progressToNext: Double
}

enum CEFRMapper {
    /// 按词族数给出 CEFR 进度。
    /// @ai: 阈值来源为常用参考值（A1≈500 / A2≈1.5k / B1≈2.5k / B2≈4.5k / C1≈8k / C2≈10k 词族），
    ///      仅作参考坐标，不作硬标准。
    static func progress(families: Double) -> CEFRProgress {
        let levels = CEFRLevel.allCases
        let current = levels.last { families >= $0.minFamilies }
        guard let next = levels.first(where: { families < $0.minFamilies }) else {
            return CEFRProgress(current: current, next: nil,
                                remainingFamilies: 0, progressToNext: 1)
        }
        let lower = current?.minFamilies ?? 0
        let span = next.minFamilies - lower
        let done = max(0, families - lower)
        return CEFRProgress(current: current, next: next,
                            remainingFamilies: max(0, next.minFamilies - families),
                            progressToNext: span > 0 ? min(1, done / span) : 0)
    }
}

// MARK: - 负载预测

/// 未来某一天的到期负载。
struct ForecastDay: Identifiable, Equatable, Sendable {
    var id: String { date }
    let date: String
    let due: Int
}

enum ForecastBuilder {

    /// 把到期时间铺到未来 `days` 天（第 0 天 = 今天）。
    /// - Parameter dueDates: 复习队列内卡片的到期时间；nil = 新卡（视为立即到期）。
    /// 已过期与 nil 都归入第 0 天；超出时间窗的忽略。
    static func forecast(dueDates: [Date?], days: Int, now: Date = Date(),
                         calendar: Calendar = .current) -> [ForecastDay] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var counts = Array(repeating: 0, count: days)
        for due in dueDates {
            guard let due else { counts[0] += 1; continue }
            let dueDay = calendar.startOfDay(for: due)
            let offset = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
            guard offset < days else { continue }
            counts[max(0, offset)] += 1
        }
        return (0..<days).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return ForecastDay(date: DayKey.string(from: date, calendar: calendar),
                               due: counts[offset])
        }
    }

    /// 今日负载（含已过期与新卡）。
    static func todayLoad(_ forecast: [ForecastDay]) -> Int {
        forecast.first?.due ?? 0
    }

    /// 峰值日（到期最多的一天）；全为 0 时返回 nil。
    static func peak(_ forecast: [ForecastDay]) -> ForecastDay? {
        guard let maxDue = forecast.map(\.due).max(), maxDue > 0 else { return nil }
        return forecast.first { $0.due == maxDue }
    }

    /// 折线 / 柱状图点（label = 日期）。
    static func points(_ forecast: [ForecastDay]) -> [ChartPoint] {
        forecast.map { ChartPoint(label: $0.date, value: Double($0.due)) }
    }
}
