// @ai: AI 合同文件 — 集中所有枚举与值类型。
// 不得改 case 顺序、不得改 rawValue、不得删除 case。
// 新增 case 只能追加到末尾。
import Foundation

// MARK: - EntityID

typealias EntityID = String

// MARK: - NodeKind

enum NodeKind: String, Sendable, Codable, CaseIterable {
    case lemma
    case card
    case deck
    case sentence
    case article
    case event
    case edge
}

// MARK: - EdgeRel
// 有向边的语义标签，对应 spec §3.3 的 12 种关系。

enum EdgeRel: String, Sendable, Codable, CaseIterable {
    case has
    case instantiates
    case hasState = "has_state"
    case produces
    case appearsIn = "appears_in"
    case translatesTo = "translates_to"
    case aggregatesTo = "aggregates_to"
    case contains
    case highlightedIn = "highlighted_in"
    case mapsTo = "maps_to"
    case owns
    case hasMedia = "has_media"
}

// MARK: - ComponentID
// 每个 comp_* 组件表的标识，case 名 = 表名去 comp_ 前缀。

enum ComponentID: String, Sendable, Codable, CaseIterable {
    case text
    case lemmaMeta = "lemma_meta"
    case deckMeta = "deck_meta"
    case scheduleState = "schedule_state"
    case reviewEvent = "review_event"
    case mediaRefs = "media_refs"
    case generationMeta = "generation_meta"
    case edgeSpan = "edge_span"
    case edgeWeighted = "edge_weighted"
    case edgePosition = "edge_position"
    case tagSet = "tag_set"
    case order
    case customData = "custom_data"
    case importFailure = "import_failure"
    case analyticsCache = "analytics_cache"
}

// MARK: - Rating

enum Rating: Int, Sendable, Codable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

// MARK: - SchedulerID

enum SchedulerID: String, Sendable, Codable, CaseIterable {
    case fsrsV4 = "fsrs-v4"
    case sm2 = "sm-2"
}

// MARK: - DeckSourceKind

enum DeckSourceKind: String, Sendable, Codable, CaseIterable {
    case anki
    case csv
    case manual
}

// MARK: - GenerationMode

enum GenerationMode: String, Sendable, Codable, CaseIterable {
    case generate
    case rewrite
}

// MARK: - QualityTier

enum QualityTier: String, Sendable, Codable, CaseIterable {
    case fast
    case local
    case remote
}

// MARK: - GenerationConstraints

struct GenerationConstraints: Sendable, Codable {
    var maxWords: Int = 300
    var language: String = "auto"
    var preserveTone: Bool = true
    var synonymDistance: Double = 0.4
}
