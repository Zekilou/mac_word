import Foundation

/// GraphQueries 返回的值类型集合（DTO）。
/// @ai: 仅数据 struct，无行为；新增查询结果类型追加到此文件。

/// 子图：节点集合 + 两端均在集合内的边。
public struct Subgraph: Sendable, Equatable {
    public let nodeIds: Set<EntityID>
    public let edges: [EdgeRecord]
}

/// 同义词查询结果：对端 lemma id + 表面形式 + 权重 + 来源类型。
public struct SynonymInfo: Sendable, Equatable {
    public let lemmaId: EntityID
    public let surfaceForm: String?
    public let weight: Double?
    public let sourceType: String?
}

/// 生成历史列表项：Article 摘要。
public struct ArticleHistoryItem: Sendable, Equatable, Identifiable {
    public let id: EntityID
    public let createdAt: Date
    public let bodyPreview: String
    public let generatorId: String
}

/// 回看的完整 Article：正文 + spans + 生成器。
public struct StoredArticle: Sendable, Equatable {
    public let id: EntityID
    public let createdAt: Date
    public let body: String
    public let spans: [SpanInfo]
    public let generatorId: String
}

/// 词库摘要：Deck 列表项。
public struct DeckSummary: Sendable, Equatable, Identifiable, Hashable {
    public let id: EntityID
    public let name: String
    public let sourceKind: String?
    public let cardCount: Int
    public let createdAt: Date
}

/// 同义词映射列表项：展示源词 → 同义词（带 edgeId 供删除）。
public struct SynonymMapping: Sendable, Equatable, Identifiable {
    public var id: String { edgeId }
    public let edgeId: EntityID
    public let fromLemmaId: EntityID
    public let toLemmaId: EntityID
    public let fromText: String
    public let toText: String
    public let weight: Double
    public let sourceType: String
    public let createdAt: Date
}

/// 搜索到的 Lemma 候选项（同义词添加面板的自动补全）。
public struct LemmaCandidate: Sendable, Equatable, Identifiable {
    public var id: EntityID { lemmaId }
    public let lemmaId: EntityID
    public let text: String
    public let definition: String?

    public init(lemmaId: EntityID, text: String, definition: String?) {
        self.lemmaId = lemmaId
        self.text = text
        self.definition = definition
    }

    /// 统一词快照（同义词候选只有词面与释义，其余留空）。
    public var word: WordCore {
        WordCore(lemmaId: lemmaId, text: text, definition: definition)
    }
}

/// Deck 内一张卡片（Card 节点）的视图：**卡片身份 + 完整词快照**。
///
/// @ai: 本轮收敛的关键——它现在内部**只持有 `WordCore`**，不再自己平铺 10 个字段。
///      以前它的字段是 `CardListItem` 私有的一份，导致：
///        · 词频带 `band`、`rank`、`updatedAt` 在卡片侧根本不存在 → 卡片浏览页无法按词频筛
///        · 同一个词在不同列表里的口径要各维护一次
///      现在 `band`/`rank`/`updatedAt`/`schedule` 全部随 `WordCore` 一起过来，
///      卡片浏览页的筛选维度与词列表完全一致。
///
///      兼容性：保留了全部旧属性名作为转发计算属性，所以现有 UI 与测试无需改动。
public struct CardListItem: Sendable, Equatable, Identifiable {
    public var id: EntityID { cardId }

    public let cardId: EntityID
    /// 完整词快照（唯一数据来源）。
    public let word: WordCore

    public init(cardId: EntityID, word: WordCore) {
        self.cardId = cardId
        self.word = word
    }

    // MARK: 转发到 word（保持旧签名可用）

    public var lemmaId: EntityID { word.lemmaId }
    /// 干净单词（text_a，可能带音标尾巴，见 plainText）
    public var text: String { word.text }
    /// 释义（text_b）
    public var definition: String? { word.definition }
    /// 复习状态（可空：未排程）
    public var dueAt: Date? { word.schedule?.dueAt }
    public var intervalDays: Double? { word.schedule?.intervalDays }
    public var reps: Int? { word.schedule?.reps }
    /// 全局掌握度（comp_user_known.mastery）
    public var mastery: Double? { word.mastery }
    /// 出现过次数（seen_count，RSS 等自动累计）
    public var seenCount: Int { word.seenCount }
    /// BKT 后验掌握度概率；nil = 尚无事件。
    public var belief: Double? { word.belief }
    /// 词频带 1..25；nil = 表外。
    public var band: Int? { word.band }
    /// 全表排名。
    public var rank: Int? { word.rank }
    /// 掌握度记录更新时间。
    public var updatedAt: Date? { word.updatedAt }
}

extension CardListItem {
    /// 便捷构造（测试与旧调用点用）：把扁平字段包成 `WordCore`。
    /// @ai: 这是**过渡构造器**。新代码应直接用 `CardListItem(cardId:word:)`，
    ///      这样词频带等新字段才不会在构造时丢掉。
    public init(cardId: EntityID, lemmaId: EntityID, text: String, definition: String?,
                dueAt: Date?, intervalDays: Double?, reps: Int?, mastery: Double?,
                seenCount: Int, belief: Double? = nil) {
        self.init(cardId: cardId, word: WordCore(
            lemmaId: lemmaId, text: text, definition: definition,
            mastery: mastery, belief: belief, seenCount: seenCount,
            schedule: dueAt != nil || reps != nil
                ? WordCore.CardSchedule(
                    cardId: cardId, dueAt: dueAt, intervalDays: intervalDays,
                    reps: reps ?? 0, lapses: 0, lastReviewedAt: nil)
                : nil))
    }

    /// 纯单词形式：剥离 "[音标]" / "(词性)" 尾巴，用于 UI 展示与匹配。
    public var plainText: String { word.plainText }
}

/// Lemma 详情（卡片浏览器右侧详情面板用）。
public struct LemmaDetail: Sendable, Equatable {
    public let lemmaId: EntityID
    public let text: String
    public let definition: String?
    public let pos: String?
    /// 已定义的同义词（maps_to 边另一侧）。
    public let synonyms: [SynonymInfo]
    /// 该词出现过的生成文章标题摘要。
    public let articles: [ArticleHit]
}

public struct ArticleHit: Sendable, Equatable {
    public let articleId: EntityID
    public let preview: String
    public let createdAt: Date
}
