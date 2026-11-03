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

/// Deck 内一张卡片（Card 节点）的词面视图：单词 + 释义 + 复习状态 + 全局掌握度。
/// @ai: mastery/seenCount 来自全局唯一数据源 comp_user_known（挂 Lemma），与词汇 Tab 同口径——
///      词包展示必须带上，保证"一个词一份掌握度"在卡片侧可见。
public struct CardListItem: Sendable, Equatable, Identifiable {
    public var id: EntityID { cardId }
    public let cardId: EntityID
    public let lemmaId: EntityID
    /// 干净单词（text_a，可能带音标尾巴，见 plainText）
    public let text: String
    /// 释义（text_b）
    public let definition: String?
    /// 复习状态（可空：未排程）
    public let dueAt: Date?
    public let intervalDays: Double?
    public let reps: Int?
    /// 全局掌握度（comp_user_known.mastery：0=无记录 / 1=不会 / 2=会 / 1~2 渐变；nil=从未标记）
    public let mastery: Double?
    /// 出现过次数（seen_count，RSS 等自动累计）
    public let seenCount: Int
    /// BKT 后验掌握度概率；nil = 尚无事件。
    public var belief: Double? = nil

    public init(cardId: EntityID, lemmaId: EntityID, text: String, definition: String?,
                dueAt: Date?, intervalDays: Double?, reps: Int?, mastery: Double?,
                seenCount: Int, belief: Double? = nil) {
        self.cardId = cardId
        self.lemmaId = lemmaId
        self.text = text
        self.definition = definition
        self.dueAt = dueAt
        self.intervalDays = intervalDays
        self.reps = reps
        self.mastery = mastery
        self.seenCount = seenCount
        self.belief = belief
    }
}

extension CardListItem {
    /// 纯单词形式：剥离 "[音标]" / "(词性)" 尾巴，用于 UI 展示与匹配。
    public var plainText: String {
        var end = text.startIndex
        while end < text.endIndex, text[end].isLetter || text[end] == "-" || text[end] == "'" {
            text.formIndex(after: &end)
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespaces)
    }
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
