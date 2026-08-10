import GRDB
import Foundation

/// 图查询服务层：封装 WITH RECURSIVE CTE 查询与图遍历。
/// @ai: 业务代码禁止手写 CTE，必须走本类的命名方法。
final class GraphQueries: @unchecked Sendable {
    let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 1. 1 跳邻居

    /// 返回 entityId 的 1 跳邻居（无向：src 或 dst 命中均算）。
    /// rel 为 nil 时返回所有 1 跳边；否则仅返回指定关系类型的边。
    func neighbors(
        of entityId: EntityID, rel: EdgeRel?
    ) throws -> [(srcId: EntityID, dstId: EntityID, relType: String)] {
        try database.dbWriter.read { db in
            let sql: String
            let args: [any DatabaseValueConvertible]
            if let rel {
                sql = """
                SELECT src_id, dst_id, rel_type FROM edges
                WHERE (src_id = ? OR dst_id = ?) AND rel_type = ?
                """
                args = [entityId, entityId, rel.rawValue]
            } else {
                sql = """
                SELECT src_id, dst_id, rel_type FROM edges
                WHERE src_id = ? OR dst_id = ?
                """
                args = [entityId, entityId]
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            var result: [(srcId: EntityID, dstId: EntityID, relType: String)] = []
            result.reserveCapacity(rows.count)
            for row in rows {
                result.append(
                    (srcId: row["src_id"], dstId: row["dst_id"], relType: row["rel_type"])
                )
            }
            return result
        }
    }

    // MARK: - 2. 子图（WITH RECURSIVE CTE）

    /// 从 lemmaId 出发 depth 跳的子图（无向遍历）。
    /// 超过 5 跳时 print warning。返回子图节点集合与两端均在集合内的边。
    func contextSubgraph(for lemmaId: EntityID, depth: Int) throws -> Subgraph {
        try database.dbWriter.read { db in
            if depth > 5 {
                print("warning: contextSubgraph depth \(depth) > 5 may be expensive")
            }
            // 无向 BFS：UNION 去重 (node_id, depth) 防止环导致无限递归。
            let cte = """
            WITH RECURSIVE reachable(node_id, depth) AS (
                SELECT ?, 0
                UNION
                SELECT
                    CASE WHEN e.src_id = r.node_id THEN e.dst_id ELSE e.src_id END,
                    r.depth + 1
                FROM reachable r
                JOIN edges e ON e.src_id = r.node_id OR e.dst_id = r.node_id
                WHERE r.depth < ?
            )
            SELECT DISTINCT node_id FROM reachable
            """
            let nodeIds = try Set(
                String.fetchAll(db, sql: cte, arguments: [lemmaId, depth])
            )

            guard !nodeIds.isEmpty else {
                return Subgraph(nodeIds: nodeIds, edges: [])
            }
            // 两端均在子图内的边构成子图的边集
            let ph = Array(repeating: "?", count: nodeIds.count).joined(separator: ",")
            let edgesSql = """
            SELECT * FROM edges
            WHERE src_id IN (\(ph)) AND dst_id IN (\(ph))
            """
            var args: [any DatabaseValueConvertible] = []
            args.append(contentsOf: nodeIds.map { $0 as any DatabaseValueConvertible })
            args.append(contentsOf: nodeIds.map { $0 as any DatabaseValueConvertible })
            let edges = try EdgeRecord.fetchAll(
                db, sql: edgesSql, arguments: StatementArguments(args)
            )
            return Subgraph(nodeIds: nodeIds, edges: edges)
        }
    }

    // MARK: - 3. 弱词（AGAIN 率 ≥ 阈值的 lemma）

    /// 找某 deck 下 AGAIN 率 ≥ 阈值的 lemma。
    /// 路径：Deck→(has)→Card→(produces)→ReviewEvent(comp_review_event.rating=1)，
    /// 按 Lemma（Card→(instantiates)→Lemma）聚合，again/total ≥ threshold。
    func weakLemmas(
        in deckId: EntityID, thresholdAgainRatio: Double
    ) throws -> [EntityID] {
        try database.dbWriter.read { db in
            let sql = """
            SELECT inst_edge.dst_id AS lemma_id
            FROM edges has_edge
            JOIN edges inst_edge
              ON inst_edge.src_id = has_edge.dst_id
             AND inst_edge.rel_type = 'instantiates'
            JOIN edges prod_edge
              ON prod_edge.src_id = has_edge.dst_id
             AND prod_edge.rel_type = 'produces'
            JOIN comp_review_event rev
              ON rev.entity_id = prod_edge.dst_id
            WHERE has_edge.src_id = ? AND has_edge.rel_type = 'has'
            GROUP BY inst_edge.dst_id
            HAVING (1.0 * SUM(CASE WHEN rev.rating = 1 THEN 1 ELSE 0 END) / COUNT(*)) >= ?
            """
            return try String.fetchAll(
                db, sql: sql, arguments: [deckId, thresholdAgainRatio]
            )
        }
    }

    // MARK: - 4. 同义词共现

    /// 在最近 N 篇 Article 中，目标 lemma 与其他 lemma 的共现次数。
    /// 路径：Article→(contains / highlighted_in)→Lemma，同一 Article 内的 lemma 对计为共现。
    /// 返回 [(targetLemma, otherLemma, count)]，按 count 降序。
    func synonymCooccurrence(
        for lemmaIds: Set<EntityID>, inArticleCount: Int
    ) throws -> [(EntityID, EntityID, Int)] {
        guard !lemmaIds.isEmpty else { return [] }
        return try database.dbWriter.read { db in
            let targetPh = Array(repeating: "?", count: lemmaIds.count)
                .joined(separator: ",")
            let sql = """
            SELECT a1.dst_id AS lemma_a, a2.dst_id AS lemma_b, COUNT(*) AS cnt
            FROM edges a1
            JOIN edges a2
              ON a1.src_id = a2.src_id
             AND a1.dst_id != a2.dst_id
             AND a2.rel_type IN ('contains', 'highlighted_in')
            WHERE a1.rel_type IN ('contains', 'highlighted_in')
              AND a1.src_id IN (
                  SELECT id FROM nodes WHERE kind = 'article'
                  ORDER BY created_at DESC LIMIT ?
              )
              AND a1.dst_id IN (\(targetPh))
            GROUP BY a1.dst_id, a2.dst_id
            ORDER BY cnt DESC
            """
            var args: [any DatabaseValueConvertible] = [inArticleCount]
            args.append(contentsOf: lemmaIds.map { $0 as any DatabaseValueConvertible })
            let rows = try Row.fetchAll(
                db, sql: sql, arguments: StatementArguments(args)
            )
            var result: [(EntityID, EntityID, Int)] = []
            result.reserveCapacity(rows.count)
            for row in rows {
                result.append((row["lemma_a"], row["lemma_b"], row["cnt"]))
            }
            return result
        }
    }

    // MARK: - 5. 按 text_a 查 Lemma

    /// 按 comp_text.text_a 精确匹配 Lemma 节点，返回 entity_id。
    /// @ai: 内容生成器用此方法把源文中的词映射到 Lemma EntityID。
    func findLemmaId(byTextA textA: String) throws -> EntityID? {
        try database.dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT t.entity_id
                FROM comp_text t
                JOIN nodes n ON n.id = t.entity_id
                WHERE t.text_a = ? AND n.kind = 'lemma'
                LIMIT 1
                """,
                arguments: [textA])
        }
    }

    // MARK: - 6. 同义词（maps_to + comp_edge_weighted）

    /// 返回某 lemma 的所有 maps_to 同义词，附带权重 / source_type / 表面形式。
    /// 路径：edges(rel_type='maps_to') JOIN comp_edge_weighted JOIN comp_text(对端)。
    func synonyms(of lemmaId: EntityID) throws -> [SynonymInfo] {
        try database.dbWriter.read { db in
            let sql = """
            SELECT
                CASE WHEN e.src_id = ? THEN e.dst_id ELSE e.src_id END AS synonym_id,
                ew.weight_double AS weight,
                ew.source_type   AS source_type,
                t.text_a         AS surface_form
            FROM edges e
            LEFT JOIN comp_edge_weighted ew
              ON ew.entity_id = e.id
            LEFT JOIN comp_text t
              ON t.entity_id = CASE WHEN e.src_id = ? THEN e.dst_id ELSE e.src_id END
            WHERE (e.src_id = ? OR e.dst_id = ?) AND e.rel_type = 'maps_to'
            """
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: StatementArguments([lemmaId, lemmaId, lemmaId, lemmaId]))
            return rows.map { row in
                SynonymInfo(
                    lemmaId: row["synonym_id"],
                    surfaceForm: row["surface_form"],
                    weight: row["weight"],
                    sourceType: row["source_type"])
            }
        }
    }

    // MARK: - 7. 生成历史列表

    /// 最近 N 篇指定模式 Article 的摘要（id / 创建时间 / 正文预览 / 生成器）。
    /// @ai: UI 历史侧栏用此方法，禁止业务代码手写 ORDER BY created_at。
    func recentArticles(mode: GenerationMode, limit: Int) throws -> [ArticleHistoryItem] {
        try database.dbWriter.read { db in
            let sql = """
            SELECT n.id, n.created_at, t.text_a, gm.generator_id
            FROM nodes n
            JOIN comp_generation_meta gm ON gm.entity_id = n.id
            LEFT JOIN comp_text t ON t.entity_id = n.id
            WHERE n.kind = 'article' AND gm.mode = ?
            ORDER BY n.created_at DESC LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [mode.rawValue, limit])
            return rows.map { row in
                ArticleHistoryItem(
                    id: row["id"],
                    createdAt: row["created_at"],
                    bodyPreview: String((row["text_a"] ?? "").prefix(100)),
                    generatorId: row["generator_id"] ?? "")
            }
        }
    }

    // MARK: - 8. 回看单篇 Article（body + highlighted_in spans）

    /// 按 id 加载 Article 正文与其全部 highlighted_in span（含权重 / 来源）。
    /// @ai: replacedFrom 不落库，故回看 span 的 replacedFrom 恒为 nil。
    func loadArticle(id: EntityID) throws -> StoredArticle? {
        try database.dbWriter.read { db in
            let header = try Row.fetchOne(
                db,
                sql: """
                SELECT n.created_at AS created_at, t.text_a AS body, gm.generator_id AS generator_id
                FROM nodes n
                LEFT JOIN comp_text t ON t.entity_id = n.id
                LEFT JOIN comp_generation_meta gm ON gm.entity_id = n.id
                WHERE n.id = ? AND n.kind = 'article'
                """,
                arguments: [id])
            guard let header, let body: String = header["body"] else { return nil }
            let createdAt: Date = header["created_at"]
            let generatorId: String = header["generator_id"] ?? ""

            let spanRows = try Row.fetchAll(
                db,
                sql: """
                SELECT e.src_id AS lemma_id, s.surface_form, s.start, s.end, s.is_target,
                       w.weight_double AS weight, w.source_type AS source_type
                FROM edges e
                JOIN comp_edge_span s ON s.entity_id = e.id
                LEFT JOIN comp_edge_weighted w ON w.entity_id = e.id
                WHERE e.dst_id = ? AND e.rel_type = 'highlighted_in'
                ORDER BY s.start
                """,
                arguments: [id])
            let spans: [SpanInfo] = spanRows.map { row in
                SpanInfo(
                    start: row["start"], end: row["end"],
                    isTarget: row["is_target"],
                    lemmaId: row["lemma_id"],
                    surfaceForm: row["surface_form"] ?? "",
                    replacedFrom: nil,
                    weight: row["weight"], sourceType: row["source_type"])
            }
            return StoredArticle(
                id: id, createdAt: createdAt, body: body,
                spans: spans, generatorId: generatorId)
        }
    }
}
