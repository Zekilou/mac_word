import GRDB
import Foundation

/// Component: 纯数据 struct，无行为。一表 = 一个 Component 类型。
/// 所有 comp_* 表以 entity_id 为 PK + FK → nodes(id) ON DELETE CASCADE。

// MARK: - Text

struct TextComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_text"
    var entityId: String
    var textA: String?
    var textB: String?
    var language: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case textA = "text_a"
        case textB = "text_b"
        case language
    }
}

// MARK: - Lemma Meta

struct LemmaMetaComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_lemma_meta"
    var entityId: String
    var pos: String?
    var phoneticUs: String?
    var phoneticUk: String?
    var sensesJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case pos
        case phoneticUs = "phonetic_us"
        case phoneticUk = "phonetic_uk"
        case sensesJson = "senses_json"
    }
}

// MARK: - Deck Meta

struct DeckMetaComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_deck_meta"
    var entityId: String
    var name: String?
    var sourceKind: String?
    var sourcePath: String?
    var importedAt: Date?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case name
        case sourceKind = "source_kind"
        case sourcePath = "source_path"
        case importedAt = "imported_at"
    }
}

// MARK: - Schedule State

struct ScheduleStateComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_schedule_state"
    var entityId: String
    var stability: Double?
    var difficulty: Double?
    var dueAt: Date?
    var intervalDays: Double?
    var reps: Int?
    var lapses: Int?
    var lastRating: Int?
    var lastReviewedAt: Date?
    var schedulerId: String?
    var queue: String?
    var customDataJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case stability
        case difficulty
        case dueAt = "due_at"
        case intervalDays = "interval_days"
        case reps
        case lapses
        case lastRating = "last_rating"
        case lastReviewedAt = "last_reviewed_at"
        case schedulerId = "scheduler_id"
        case queue
        case customDataJson = "custom_data_json"
    }
}

// MARK: - Review Event

struct ReviewEventComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_review_event"
    var entityId: String
    var targetCardId: String?
    var ratedAt: Date?
    var rating: Int?
    var respondedMs: Int?
    var elapsedDays: Double?
    var scheduledInterval: Double?
    var deltaStability: Double?
    var deltaDifficulty: Double?
    var lastIvl: Double?
    var factor: Double?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case targetCardId = "target_card_id"
        case ratedAt = "rated_at"
        case rating
        case respondedMs = "responded_ms"
        case elapsedDays = "elapsed_days"
        case scheduledInterval = "scheduled_interval"
        case deltaStability = "delta_stability"
        case deltaDifficulty = "delta_difficulty"
        case lastIvl = "last_ivl"
        case factor
    }
}

// MARK: - Media Refs

struct MediaRefsComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_media_refs"
    var entityId: String
    var entriesJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case entriesJson = "entries_json"
    }
}

// MARK: - Generation Meta

struct GenerationMetaComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_generation_meta"
    var entityId: String
    var mode: String?
    var topic: String?
    var sourceText: String?
    var generatorId: String?
    var qualityTier: String?
    var promptHash: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case mode
        case topic
        case sourceText = "source_text"
        case generatorId = "generator_id"
        case qualityTier = "quality_tier"
        case promptHash = "prompt_hash"
    }
}

// MARK: - Edge Span

struct EdgeSpanComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_edge_span"
    var entityId: String
    var surfaceForm: String?
    var start: Int?
    var end: Int?
    var isTarget: Bool?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case surfaceForm = "surface_form"
        case start
        case end
        case isTarget = "is_target"
    }
}

// MARK: - Edge Weighted

struct EdgeWeightedComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_edge_weighted"
    var entityId: String
    var weightDouble: Double?
    var sourceType: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case weightDouble = "weight_double"
        case sourceType = "source_type"
    }
}

// MARK: - Edge Position

struct EdgePositionComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_edge_position"
    var entityId: String
    var positionInSentence: Int?
    var surfaceForm: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case positionInSentence = "position_in_sentence"
        case surfaceForm = "surface_form"
    }
}

// MARK: - Tag Set

struct TagSetComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_tag_set"
    var entityId: String
    var tagsJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case tagsJson = "tags_json"
    }
}

// MARK: - Order

struct OrderComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_order"
    var entityId: String
    var sortIndex: Int?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case sortIndex = "sort_index"
    }
}

// MARK: - Custom Data

struct CustomDataComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_custom_data"
    var entityId: String
    var payloadJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case payloadJson = "payload_json"
    }
}

// MARK: - Import Failure

struct ImportFailureComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_import_failure"
    var entityId: String
    var deckId: String?
    var rowIndex: Int?
    var rawLine: String?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case deckId = "deck_id"
        case rowIndex = "row_index"
        case rawLine = "raw_line"
        case reason
    }
}

// MARK: - Analytics Cache

struct AnalyticsCacheComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_analytics_cache"
    var entityId: String
    var moduleId: String?
    var scopeHash: String?
    var computedAt: Date?
    var payloadJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case moduleId = "module_id"
        case scopeHash = "scope_hash"
        case computedAt = "computed_at"
        case payloadJson = "payload_json"
    }
}

// MARK: - User Known
// 用户词汇掌握度：全局上下文，挂 Lemma（全库唯一），不受词包影响。
// 状态与卡片彻底分离——这里只记"会不会"，不建卡。
// mastery（unsigned float）：0 = 无记录；1 = 完全不会；2 = 完全会；1~2 连续渐变。

struct UserKnownComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_user_known"
    var entityId: String
    /// 掌握度：0 = 无记录，1 = 不会，2 = 会（1~2 连续渐变）。
    var mastery: Double
    /// 出现过次数（RSS 等文章自动记录；不判定会/不会）。0 = 从未出现在阅读文本。
    var seenCount: Int
    /// 状态来源：init（初始化标记）/ article（文章词反馈）/ manual（手动）。
    var source: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case mastery
        case seenCount = "seen_count"
        case source
        case updatedAt = "updated_at"
    }
}

// MARK: - Lemma Definition
// 多来源释义合并（挂 Lemma）：导入追加合并不覆盖，text_b 为主释义。

struct LemmaDefinitionComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_lemma_definitions"
    var entityId: String
    /// JSON 数组：[{ "source": "deck:<deckId>", "definition": "..." }]。
    var definitionsJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case definitionsJson = "definitions_json"
    }
}
