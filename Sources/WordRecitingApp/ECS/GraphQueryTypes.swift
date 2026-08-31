import Foundation

/// GraphQueries 返回的值类型集合（DTO）。
/// @ai: 仅数据 struct，无行为；新增查询结果类型追加到此文件。

/// 子图：节点集合 + 两端均在集合内的边。
struct Subgraph: Sendable, Equatable {
    let nodeIds: Set<EntityID>
    let edges: [EdgeRecord]
}

/// 同义词查询结果：对端 lemma id + 表面形式 + 权重 + 来源类型。
struct SynonymInfo: Sendable, Equatable {
    let lemmaId: EntityID
    let surfaceForm: String?
    let weight: Double?
    let sourceType: String?
}

/// 生成历史列表项：Article 摘要。
struct ArticleHistoryItem: Sendable, Equatable, Identifiable {
    let id: EntityID
    let createdAt: Date
    let bodyPreview: String
    let generatorId: String
}

/// 回看的完整 Article：正文 + spans + 生成器。
struct StoredArticle: Sendable, Equatable {
    let id: EntityID
    let createdAt: Date
    let body: String
    let spans: [SpanInfo]
    let generatorId: String
}

/// 词库摘要：Deck 列表项。
struct DeckSummary: Sendable, Equatable, Identifiable, Hashable {
    let id: EntityID
    let name: String
    let sourceKind: String?
    let cardCount: Int
    let createdAt: Date
}

/// 同义词映射列表项：展示源词 → 同义词（带 edgeId 供删除）。
struct SynonymMapping: Sendable, Equatable, Identifiable {
    var id: String { edgeId }
    let edgeId: EntityID
    let fromLemmaId: EntityID
    let toLemmaId: EntityID
    let fromText: String
    let toText: String
    let weight: Double
    let sourceType: String
    let createdAt: Date
}

/// 搜索到的 Lemma 候选项（同义词添加面板的自动补全）。
struct LemmaCandidate: Sendable, Equatable, Identifiable {
    var id: EntityID { lemmaId }
    let lemmaId: EntityID
    let text: String
    let definition: String?
}

/// Deck 内一张卡片（Card 节点）的词面视图：单词 + 释义 + 复习状态 + 全局掌握度。
/// @ai: mastery/seenCount 来自全局唯一数据源 comp_user_known（挂 Lemma），与词汇 Tab 同口径——
///      词包展示必须带上，保证"一个词一份掌握度"在卡片侧可见。
struct CardListItem: Sendable, Equatable, Identifiable {
    var id: EntityID { cardId }
    let cardId: EntityID
    let lemmaId: EntityID
    /// 干净单词（text_a，可能带音标尾巴，见 plainText）
    let text: String
    /// 释义（text_b）
    let definition: String?
    /// 复习状态（可空：未排程）
    let dueAt: Date?
    let intervalDays: Double?
    let reps: Int?
    /// 全局掌握度（comp_user_known.mastery：0=无记录 / 1=不会 / 2=会 / 1~2 渐变；nil=从未标记）
    let mastery: Double?
    /// 出现过次数（seen_count，RSS 等自动累计）
    let seenCount: Int
}

extension CardListItem {
    /// 纯单词形式：剥离 "[音标]" / "(词性)" 尾巴，用于 UI 展示与匹配。
    var plainText: String {
        var end = text.startIndex
        while end < text.endIndex, text[end].isLetter || text[end] == "-" || text[end] == "'" {
            text.formIndex(after: &end)
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespaces)
    }
}

/// Lemma 详情（卡片浏览器右侧详情面板用）。
struct LemmaDetail: Sendable, Equatable {
    let lemmaId: EntityID
    let text: String
    let definition: String?
    let pos: String?
    /// 已定义的同义词（maps_to 边另一侧）。
    let synonyms: [SynonymInfo]
    /// 该词出现过的生成文章标题摘要。
    let articles: [ArticleHit]
}

struct ArticleHit: Sendable, Equatable {
    let articleId: EntityID
    let preview: String
    let createdAt: Date
}
