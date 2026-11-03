import Foundation
import GRDB

/// Region：一次「显示词汇的上下文」（页面/会话级）。
/// @ai: id 由调用方按业务键构造，保证同一上下文复用同一 region。
struct RegionComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_region"
    var entityId: String
    /// RegionKind.rawValue。
    var kind: String
    var label: String?
    /// 触发该 region 的实体（文章 id / 卡片 id / nil）。
    var sourceId: String?
    /// 该上下文的基础可信度：主动上下文 1.0，被动上下文 0.0。
    var trust: Double
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case kind
        case label
        case sourceId = "source_id"
        case trust
        case createdAt = "created_at"
    }
}

/// 单次词事件（全量事件流的一条记录，挂 Event 节点）。
struct WordEventComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_word_event"
    var entityId: String
    /// 冗余外键：便于按词索引查询。
    var lemmaId: String
    /// 冗余外键：便于按上下文索引查询。
    var regionId: String
    /// WordEventKind.rawValue。
    var eventKind: String
    /// 事件级可信度（= 覆盖值 ?? region.trust）。
    var trust: Double
    var occurredAt: Date
    var detailJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case lemmaId = "lemma_id"
        case regionId = "region_id"
        case eventKind = "event_kind"
        case trust
        case occurredAt = "occurred_at"
        case detailJson = "detail_json"
    }
}

/// 词频族坐标（BNC/COCA 词族带，挂 Lemma 节点）。
struct LemmaFrequencyComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_lemma_frequency"
    var entityId: String
    /// 词族带：1 = 最高频 1k 带 … 25 = 25k 带。
    var band: Int
    /// 词族在全表中的排序（1 起）。
    var freqRank: Int
    var source: String

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case band
        case freqRank = "freq_rank"
        case source
    }
}
