import GRDB
import Foundation

/// Component: 纯数据 struct，无行为。一表 = 一个 Component 类型。
/// 所有 comp_* 表以 entity_id 为 PK + FK → nodes(id) ON DELETE CASCADE。

// MARK: - Text

public struct TextComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_text"
    public var entityId: String
    public var textA: String?
    public var textB: String?
    public var language: String?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case textA = "text_a"
        case textB = "text_b"
        case language
    }

    public init(entityId: String, textA: String?, textB: String?, language: String?) {
        self.entityId = entityId
        self.textA = textA
        self.textB = textB
        self.language = language
    }
}

// MARK: - Lemma Meta

public struct LemmaMetaComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_lemma_meta"
    public var entityId: String
    public var pos: String?
    public var phoneticUs: String?
    public var phoneticUk: String?
    public var sensesJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case pos
        case phoneticUs = "phonetic_us"
        case phoneticUk = "phonetic_uk"
        case sensesJson = "senses_json"
    }
}

// MARK: - Deck Meta

public struct DeckMetaComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_deck_meta"
    public var entityId: String
    public var name: String?
    public var sourceKind: String?
    public var sourcePath: String?
    public var importedAt: Date?

    public init(entityId: String, name: String?, sourceKind: String?,
                sourcePath: String?, importedAt: Date?) {
        self.entityId = entityId
        self.name = name
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.importedAt = importedAt
    }

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case name
        case sourceKind = "source_kind"
        case sourcePath = "source_path"
        case importedAt = "imported_at"
    }
}

// MARK: - Schedule State

public struct ScheduleStateComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_schedule_state"
    public var entityId: String
    public var stability: Double?
    public var difficulty: Double?
    public var dueAt: Date?
    public var intervalDays: Double?
    public var reps: Int?
    public var lapses: Int?
    public var lastRating: Int?
    public var lastReviewedAt: Date?
    public var schedulerId: String?
    public var queue: String?
    public var customDataJson: String?

    public init(entityId: String, stability: Double?, difficulty: Double?, dueAt: Date?,
                intervalDays: Double?, reps: Int?, lapses: Int?, lastRating: Int?,
                lastReviewedAt: Date?, schedulerId: String?, queue: String?,
                customDataJson: String?) {
        self.entityId = entityId
        self.stability = stability
        self.difficulty = difficulty
        self.dueAt = dueAt
        self.intervalDays = intervalDays
        self.reps = reps
        self.lapses = lapses
        self.lastRating = lastRating
        self.lastReviewedAt = lastReviewedAt
        self.schedulerId = schedulerId
        self.queue = queue
        self.customDataJson = customDataJson
    }

    public enum CodingKeys: String, CodingKey {
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

public struct ReviewEventComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_review_event"
    public var entityId: String
    public var targetCardId: String?
    public var ratedAt: Date?
    public var rating: Int?
    public var respondedMs: Int?
    public var elapsedDays: Double?
    public var scheduledInterval: Double?
    public var deltaStability: Double?
    public var deltaDifficulty: Double?
    public var lastIvl: Double?
    public var factor: Double?

    public init(entityId: String, targetCardId: String?, ratedAt: Date?, rating: Int?,
                respondedMs: Int?, elapsedDays: Double?, scheduledInterval: Double?,
                deltaStability: Double?, deltaDifficulty: Double?, lastIvl: Double?,
                factor: Double?) {
        self.entityId = entityId
        self.targetCardId = targetCardId
        self.ratedAt = ratedAt
        self.rating = rating
        self.respondedMs = respondedMs
        self.elapsedDays = elapsedDays
        self.scheduledInterval = scheduledInterval
        self.deltaStability = deltaStability
        self.deltaDifficulty = deltaDifficulty
        self.lastIvl = lastIvl
        self.factor = factor
    }

    public enum CodingKeys: String, CodingKey {
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

/// 媒体引用组件（设计文档 §3.4 comp_media_refs）。
/// 规划用途：Anki .apkg 导入时解析 [sound:xxx.mp3] / <img src="xxx"> → media refs，
/// 媒体文件落地到 AppSupport（§6）。阶段一仅建表占位，阶段二 AnkiImporter 完整接入后消费。
/// @ai: 属规划 Component，勿删。
public struct MediaRefsComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_media_refs"
    public var entityId: String
    public var entriesJson: String?

    public init(entityId: String, entriesJson: String?) {
        self.entityId = entityId
        self.entriesJson = entriesJson
    }

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case entriesJson = "entries_json"
    }
}

// MARK: - Generation Meta

public struct GenerationMetaComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_generation_meta"
    public var entityId: String
    public var mode: String?
    public var topic: String?
    public var sourceText: String?
    public var generatorId: String?
    public var qualityTier: String?
    public var promptHash: String?

    public init(entityId: String, mode: String?, topic: String?, sourceText: String?,
                generatorId: String?, qualityTier: String?, promptHash: String?) {
        self.entityId = entityId
        self.mode = mode
        self.topic = topic
        self.sourceText = sourceText
        self.generatorId = generatorId
        self.qualityTier = qualityTier
        self.promptHash = promptHash
    }

    public enum CodingKeys: String, CodingKey {
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

public struct EdgeSpanComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_edge_span"
    public var entityId: String
    public var surfaceForm: String?
    public var start: Int?
    public var end: Int?
    public var isTarget: Bool?

    public init(entityId: String, surfaceForm: String?, start: Int?, end: Int?,
                isTarget: Bool?) {
        self.entityId = entityId
        self.surfaceForm = surfaceForm
        self.start = start
        self.end = end
        self.isTarget = isTarget
    }

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case surfaceForm = "surface_form"
        case start
        case end
        case isTarget = "is_target"
    }
}

// MARK: - Edge Weighted

public struct EdgeWeightedComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_edge_weighted"
    public var entityId: String
    public var weightDouble: Double?
    public var sourceType: String?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case weightDouble = "weight_double"
        case sourceType = "source_type"
    }

    public init(entityId: String, weightDouble: Double?, sourceType: String?) {
        self.entityId = entityId
        self.weightDouble = weightDouble
        self.sourceType = sourceType
    }
}

// MARK: - Edge Position

public struct EdgePositionComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_edge_position"
    public var entityId: String
    public var positionInSentence: Int?
    public var surfaceForm: String?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case positionInSentence = "position_in_sentence"
        case surfaceForm = "surface_form"
    }

    public init(entityId: String, positionInSentence: Int?, surfaceForm: String?) {
        self.entityId = entityId
        self.positionInSentence = positionInSentence
        self.surfaceForm = surfaceForm
    }
}

// MARK: - Tag Set

public struct TagSetComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_tag_set"
    public var entityId: String
    public var tagsJson: String?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case tagsJson = "tags_json"
    }

    public init(entityId: String, tagsJson: String?) {
        self.entityId = entityId
        self.tagsJson = tagsJson
    }
}

// MARK: - Order

public struct OrderComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_order"
    public var entityId: String
    public var sortIndex: Int?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case sortIndex = "sort_index"
    }

    public init(entityId: String, sortIndex: Int?) {
        self.entityId = entityId
        self.sortIndex = sortIndex
    }
}

// MARK: - Custom Data

public struct CustomDataComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_custom_data"
    public var entityId: String
    public var payloadJson: String?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case payloadJson = "payload_json"
    }

    public init(entityId: String, payloadJson: String?) {
        self.entityId = entityId
        self.payloadJson = payloadJson
    }
}

// MARK: - Import Failure

public struct ImportFailureComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_import_failure"
    public var entityId: String
    public var deckId: String?
    public var rowIndex: Int?
    public var rawLine: String?
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case deckId = "deck_id"
        case rowIndex = "row_index"
        case rawLine = "raw_line"
        case reason
    }

    public init(entityId: String, deckId: String?, rowIndex: Int?,
                rawLine: String?, reason: String?) {
        self.entityId = entityId
        self.deckId = deckId
        self.rowIndex = rowIndex
        self.rawLine = rawLine
        self.reason = reason
    }
}

// MARK: - Analytics Cache

public struct AnalyticsCacheComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_analytics_cache"
    public var entityId: String
    public var moduleId: String?
    public var scopeHash: String?
    public var computedAt: Date?
    public var payloadJson: String?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case moduleId = "module_id"
        case scopeHash = "scope_hash"
        case computedAt = "computed_at"
        case payloadJson = "payload_json"
    }

    public init(entityId: String, moduleId: String?, scopeHash: String?,
                computedAt: Date?, payloadJson: String?) {
        self.entityId = entityId
        self.moduleId = moduleId
        self.scopeHash = scopeHash
        self.computedAt = computedAt
        self.payloadJson = payloadJson
    }
}

// MARK: - User Known
// 用户词汇掌握度：全局上下文，挂 Lemma（全库唯一），不受词包影响。
// 状态与卡片彻底分离——这里只记"会不会"，不建卡。
// mastery（unsigned float）：0 = 无记录；1 = 完全不会；2 = 完全会；1~2 连续渐变。

public struct UserKnownComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_user_known"
    public var entityId: String
    /// 掌握度：0 = 无记录，1 = 不会，2 = 会（1~2 连续渐变）。
    public var mastery: Double
    /// 出现过次数（RSS 等文章自动记录；不判定会/不会）。0 = 从未出现在阅读文本。
    public var seenCount: Int
    /// 状态来源：init（初始化标记）/ article（文章词反馈）/ manual（手动）。
    public var source: String
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case mastery
        case seenCount = "seen_count"
        case source
        case updatedAt = "updated_at"
    }

    public init(entityId: String, mastery: Double, seenCount: Int,
                source: String, updatedAt: Date) {
        self.entityId = entityId
        self.mastery = mastery
        self.seenCount = seenCount
        self.source = source
        self.updatedAt = updatedAt
    }
}

// MARK: - Lemma Definition
// 多来源释义合并（挂 Lemma）：导入追加合并不覆盖，text_b 为主释义。

public struct LemmaDefinitionComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "comp_lemma_definitions"
    public var entityId: String
    /// JSON 数组：[{ "source": "deck:<deckId>", "definition": "..." }]。
    public var definitionsJson: String?

    public enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case definitionsJson = "definitions_json"
    }

    public init(entityId: String, definitionsJson: String?) {
        self.entityId = entityId
        self.definitionsJson = definitionsJson
    }
}
