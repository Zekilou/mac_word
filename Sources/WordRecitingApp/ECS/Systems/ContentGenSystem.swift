import GRDB
import Foundation

/// ContentGenSystem：在单个写事务内把 GeneratedArticle 落库。
/// 步骤：
///  1. INSERT ArticleNode
///  2. UPSERT comp_text（body）
///  3. UPSERT comp_generation_meta（mode/topic/source/generator/tier）
///  4. 每个 SpanInfo 有 lemmaId → INSERT highlighted_in edge + comp_edge_span
///  5. 替换型 span 有 weight → INSERT comp_edge_weighted
/// @ai: requiresAll = []（创建新实体，不依赖已有签名过滤）。
struct ContentGenSystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = ContentGenContext

    func execute(world: World, db: Database, entities: [EntityID], context: ContentGenContext) throws {
        let now = Date()
        let articleId = "article-\(UUID().uuidString)"
        let article = context.article

        // 1. INSERT ArticleNode
        try world.registry.insertNode(db, id: articleId, kind: .article, createdAt: now)

        // 2. UPSERT comp_text
        try world.registry.upsertComponent(db, TextComponent(
            entityId: articleId, textA: article.body, textB: nil, language: nil))

        // 3. UPSERT comp_generation_meta
        try world.registry.upsertComponent(db, GenerationMetaComponent(
            entityId: articleId,
            mode: GenerationMode.rewrite.rawValue,
            topic: context.topic,
            sourceText: context.sourceText,
            generatorId: article.generatorId,
            qualityTier: article.tier.rawValue,
            promptHash: nil))

        // 4. 每个 SpanInfo → highlighted_in edge + comp_edge_span
        for (i, span) in article.spans.enumerated() {
            guard let lemmaId = span.lemmaId else { continue }
            let edgeId = "hl-\(articleId)-\(i)"
            try world.registry.insertEdge(
                db, id: edgeId, srcId: lemmaId, dstId: articleId,
                rel: .highlightedIn, createdAt: now)
            try world.registry.upsertComponent(db, EdgeSpanComponent(
                entityId: edgeId, surfaceForm: span.surfaceForm,
                start: span.start, end: span.end, isTarget: span.isTarget))
            // 5. 替换型 span 有 weight → comp_edge_weighted
            if let weight = span.weight {
                try world.registry.upsertComponent(db, EdgeWeightedComponent(
                    entityId: edgeId, weightDouble: weight, sourceType: span.sourceType))
            }
        }
    }
}

/// ContentGenSystem 的上下文：生成的文章 + 目标词列表 + 源文（可选）+ 主题（可选）。
struct ContentGenContext: Sendable {
    let article: GeneratedArticle
    let targetLemmas: [EntityID]
    let sourceText: String?
    let topic: String?
}
