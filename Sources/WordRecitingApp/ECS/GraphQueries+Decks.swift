import GRDB
import Foundation

/// GraphQueries 扩展：Deck 管理相关查询。
/// @ai: 业务代码禁止手写 SQL，必须走 GraphQueries 的命名方法。
extension GraphQueries {

    /// 返回所有 Deck 节点及其卡片数，按创建时间降序。
    func allDecks() throws -> [DeckSummary] {
        try database.dbWriter.read { db in
            let sql = """
            SELECT n.id, n.created_at, dm.name, dm.source_kind,
                   (SELECT COUNT(*) FROM edges e
                    WHERE e.src_id = n.id AND e.rel_type = 'has') AS card_count
            FROM nodes n
            JOIN comp_deck_meta dm ON dm.entity_id = n.id
            WHERE n.kind = 'deck'
            ORDER BY n.created_at DESC
            """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map { row in
                DeckSummary(
                    id: row["id"], name: row["name"] ?? "(unnamed)",
                    sourceKind: row["source_kind"], cardCount: row["card_count"] ?? 0,
                    createdAt: row["created_at"])
            }
        }
    }

    /// 搜索某 deck 下所有 Lemma 的 text_a（用于目标词自动补全）。
    func lemmas(in deckId: EntityID, limit: Int = 200) throws -> [(id: EntityID, text: String)] {
        try database.dbWriter.read { db in
            let sql = """
            SELECT t.entity_id, t.text_a
            FROM edges has_edge
            JOIN edges inst_edge ON inst_edge.src_id = has_edge.dst_id AND inst_edge.rel_type = 'instantiates'
            JOIN comp_text t ON t.entity_id = inst_edge.dst_id
            WHERE has_edge.src_id = ? AND has_edge.rel_type = 'has'
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [deckId, limit])
            return rows.map { row in
                // @ai: 必须清洗——脏词面（Anki HTML / [sound:] 残留）会原样出现在
                //      造文页选词清单里，也可能被当成目标词写进 prompt。
                (id: row["entity_id"],
                 text: TextSanitizer.clean(row["text_a"], preserveLineBreaks: false) ?? "")
            }
        }
    }
}
