import Foundation

/// 一个词元在决策时需要的全部特征（词频 + 概率 + 事件流 + 卡片调度）。
/// @ai: 纯值类型，策略只消费它、不碰数据库。
struct WordFeatures: Sendable, Equatable {
    let lemmaId: EntityID
    /// BKT 后验概率；nil = 尚无事件。
    let belief: Double?
    /// 词频带 1..25；nil = 无坐标（词表外或词表未加载）。
    let band: Int?
    /// 全表排名。
    let rank: Int?
    /// 词事件总数。
    let eventCount: Int
    /// 不同 region 数（上下文多样性 CD）。
    let contextCount: Int
    /// 最近一次事件时间。
    let lastEventAt: Date?
    /// 卡片调度状态；无卡 = nil。
    let card: CardSchedule?

    /// 卡片调度状态（一个 Lemma 只取一张卡）。
    struct CardSchedule: Sendable, Equatable {
        let cardId: EntityID
        let dueAt: Date?
        let reps: Int
        let lapses: Int
        let intervalDays: Double?
        /// 上次复习时间；「实际经过天数」= now − lastReviewedAt，由策略自算（不额外查库）。
        let lastReviewedAt: Date?
    }
}
