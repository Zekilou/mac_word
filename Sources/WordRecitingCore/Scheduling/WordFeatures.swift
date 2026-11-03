import Foundation

/// 一个词元在决策时需要的全部特征（词频 + 概率 + 事件流 + 卡片调度）。
/// @ai: 纯值类型，策略只消费它、不碰数据库。
public struct WordFeatures: Sendable, Equatable {
    public let lemmaId: EntityID
    /// BKT 后验概率；nil = 尚无事件。
    public let belief: Double?
    /// 词频带 1..25；nil = 无坐标（词表外或词表未加载）。
    public let band: Int?
    /// 全表排名。
    public let rank: Int?
    /// 词事件总数。
    public let eventCount: Int
    /// 不同 region 数（上下文多样性 CD）。
    public let contextCount: Int
    /// 最近一次事件时间。
    public let lastEventAt: Date?
    /// 卡片调度状态；无卡 = nil。
    public let card: CardSchedule?

    /// 全参构造：除 lemmaId 外全部有默认值，让「只知道一部分特征」的调用点
    /// （测试 / 调度兜底）可以只写关心的那几个。
    /// @ai: 默认值必须保持「什么都不知道」的中性语义——不要给 belief 填 0，
    ///      0 与 nil 在这个模型里是两种含义（概率为 0 vs 无概率）。
    public init(
        lemmaId: EntityID,
        belief: Double? = nil,
        band: Int? = nil,
        rank: Int? = nil,
        eventCount: Int = 0,
        contextCount: Int = 0,
        lastEventAt: Date? = nil,
        card: CardSchedule? = nil
    ) {
        self.lemmaId = lemmaId
        self.belief = belief
        self.band = band
        self.rank = rank
        self.eventCount = eventCount
        self.contextCount = contextCount
        self.lastEventAt = lastEventAt
        self.card = card
    }

    /// 卡片调度状态（一个 Lemma 只取一张卡）。
    public struct CardSchedule: Sendable, Equatable {
        public let cardId: EntityID
        public let dueAt: Date?
        public let reps: Int
        public let lapses: Int
        public let intervalDays: Double?
        /// 上次复习时间；「实际经过天数」= now − lastReviewedAt，由策略自算（不额外查库）。
        public let lastReviewedAt: Date?
    }
}
