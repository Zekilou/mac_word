import GRDB
import Foundation

/// GraphQueries 扩展：同义词管理相关查询（UI 列表 + 搜索候选）。
/// @ai: 业务代码禁止手写 SQL，必须走 GraphQueries 的命名方法。
extension GraphQueries {

    // MARK: - 1. 同义词搜索候选

    /// 按 text_a 前缀搜索所有 Lemma 节点（大小写不敏感），返回候选列表。
    /// @ai: 同义词添加面板用此方法做自动补全。空 prefix 直接返回空数组。
    func searchLemmas(prefix: String, limit: Int = 50) throws -> [LemmaCandidate] {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return try database.dbWriter.read { db in
            let likePattern = trimmed.lowercased() + "%"
            let sql = """
            SELECT
                n.id            AS lemma_id,
                t.text_a        AS text,
                t.text_b        AS definition
            FROM comp_text t
            JOIN nodes n ON n.id = t.entity_id
            WHERE n.kind = 'lemma' AND LOWER(t.text_a) LIKE ?
            ORDER BY t.text_a
            LIMIT ?
            """
            let rows = try Row.fetchAll(
                db, sql: sql, arguments: [likePattern, limit])
            return rows.map { row in
                LemmaCandidate(
                    lemmaId: row["lemma_id"],
                    text: TextSanitizer.clean(row["text"], preserveLineBreaks: false) ?? "",
                    definition: TextSanitizer.clean(
                        row["definition"], preserveLineBreaks: true))
            }
        }
    }

    // MARK: - 2. 列出所有同义词映射

    /// 返回所有已定义的 maps_to 同义词映射，按创建时间降序。
    /// @ai: SynonymManager 列表用此方法展示全部同义词对。
    func listAllSynonymMappings() throws -> [SynonymMapping] {
        try database.dbWriter.read { db in
            let sql = """
            SELECT
                e.id            AS edge_id,
                e.src_id        AS from_id,
                e.dst_id        AS to_id,
                e.created_at    AS created_at,
                COALESCE(ew.weight_double, 0.5) AS weight,
                COALESCE(ew.source_type, 'manual') AS source_type,
                ft.text_a       AS from_text,
                tt.text_a       AS to_text
            FROM edges e
            LEFT JOIN comp_edge_weighted ew ON ew.entity_id = e.id
            LEFT JOIN comp_text ft ON ft.entity_id = e.src_id
            LEFT JOIN comp_text tt ON tt.entity_id = e.dst_id
            WHERE e.rel_type = 'maps_to'
            ORDER BY e.created_at DESC
            """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map { row in
                SynonymMapping(
                    edgeId: row["edge_id"],
                    fromLemmaId: row["from_id"],
                    toLemmaId: row["to_id"],
                    // @ai: 两端词面同样要清洗，否则同义词列表会显示 HTML 残留。
                    fromText: TextSanitizer.clean(
                        row["from_text"], preserveLineBreaks: false) ?? "",
                    toText: TextSanitizer.clean(
                        row["to_text"], preserveLineBreaks: false) ?? "",
                    weight: row["weight"] ?? 0.5,
                    sourceType: row["source_type"] ?? "manual",
                    createdAt: row["created_at"])
            }
        }
    }

    // MARK: - 3. 检查两 lemma 间是否已存在 maps_to 边（任方向）

    /// 返回两个 lemma 间已存在的 maps_to 边 id，未找到返回 nil。
    /// @ai: SynonymSystem 添加前用于幂等（避免重复插入）。
    func findMapsToEdgeId(_ db: Database, a: EntityID, b: EntityID) throws -> EntityID? {
        let sql = """
        SELECT id FROM edges
        WHERE rel_type = 'maps_to'
          AND ((src_id = ? AND dst_id = ?) OR (src_id = ? AND dst_id = ?))
        LIMIT 1
        """
        return try String.fetchOne(
            db, sql: sql, arguments: [a, b, b, a])
    }
}
