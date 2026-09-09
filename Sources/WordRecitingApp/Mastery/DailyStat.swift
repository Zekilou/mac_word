import Foundation

/// 每日统计快照（趋势数据源）。
/// 存储：`nodes(kind='analytics_day')` + `comp_analytics_cache(module_id='daily_stat', scope_hash=date)`。
/// 口径：与概率主口径一致（`WordMarkState` 阈值），由 `DailyStatRecorder` 单遍重放词事件流生成。
struct DailyStat: Codable, Sendable, Equatable {
    /// 本地日期 `yyyy-MM-dd`。
    let date: String
    /// 后验 ≥ knownThreshold 的词数。
    let known: Int
    /// 后验在 (unknownThreshold, knownThreshold) 之间的词数。
    let learning: Int
    /// 后验 ≤ unknownThreshold 的词数。
    let unknown: Int
    /// 当天的词事件数。
    let events: Int
    /// 当天首次出现（首个词事件落在当天）的词数。
    let newWords: Int
    /// 当天的复习评分次数。
    let reviews: Int
    /// 当天真实保留率 = 评分 ≥ good 的占比；无复习为 nil。
    let retention: Double?
    /// 词频带（字符串）→ 当天后验 ≥ knownThreshold 的词数。
    let knownByBand: [String: Int]

    /// 有后验的词总数（= known + learning + unknown）。
    var observed: Int { known + learning + unknown }
}
