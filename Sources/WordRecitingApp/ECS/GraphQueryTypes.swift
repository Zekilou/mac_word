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
