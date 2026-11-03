import Foundation

/// 每日统计快照（趋势数据源）。
/// 存储：`nodes(kind='analytics_day')` + `comp_analytics_cache(module_id='daily_stat', scope_hash=date)`。
/// 口径：与概率主口径一致（`WordMarkState` 阈值），由 `DailyStatRecorder` 单遍重放词事件流生成。
public struct DailyStat: Codable, Sendable, Equatable {
    /// 本地日期 `yyyy-MM-dd`。
    public let date: String
    /// 后验 ≥ knownThreshold 的词数。
    public let known: Int
    /// 后验在 (unknownThreshold, knownThreshold) 之间的词数。
    public let learning: Int
    /// 后验 ≤ unknownThreshold 的词数。
    public let unknown: Int
    /// 当天的词事件数。
    public let events: Int
    /// 当天首次出现（首个词事件落在当天）的词数。
    public let newWords: Int
    /// 当天的复习评分次数。
    public let reviews: Int
    /// 当天真实保留率 = 评分 ≥ good 的占比；无复习为 nil。
    public let retention: Double?
    /// 词频带（字符串）→ 当天后验 ≥ knownThreshold 的词数。
    public let knownByBand: [String: Int]
    /// 当天收盘时的词汇量估算（词族数，含未观测词按先验外推）；无法估算为 nil。
    public var estimatedFamilies: Double? = nil

    /// 有后验的词总数（= known + learning + unknown）。
    public var observed: Int { known + learning + unknown }
}

/// 本地自然日键 `yyyy-MM-dd`（`DailyStat.date` 与图表 x 轴共用）。
public enum DayKey {
    public static func string(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 解析失败返回 nil（格式不是 `yyyy-MM-dd`）。
    static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
