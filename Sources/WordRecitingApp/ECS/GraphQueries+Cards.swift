import GRDB
import Foundation

/// GraphQueries 扩展：Deck 内卡片浏览 + Lemma 详情。
/// @ai: 业务代码禁止手写 SQL，必须走 GraphQueries 的命名方法。
extension GraphQueries {

    /// 返回某 deck 下的所有卡片（Card 节点 + 关联 Lemma 词面 + 复习状态），
    /// 按单词字母序排序。
    func cardsInDeck(_ deckId: EntityID, limit: Int = 5000) throws -> [CardListItem] {
        try database.dbWriter.read { db in
            let sql = """
            SELECT
                c.id            AS card_id,
                t.entity_id     AS lemma_id,
                t.text_a        AS text,
                t.text_b        AS definition,
                ss.due_at       AS due_at,
                ss.interval_days AS interval_days,
                ss.reps         AS reps,
                uk.mastery      AS mastery,
                uk.seen_count   AS seen_count
            FROM edges has_edge
            JOIN nodes c ON c.id = has_edge.dst_id AND c.kind = 'card'
            JOIN edges inst_edge ON inst_edge.src_id = c.id AND inst_edge.rel_type = 'instantiates'
            JOIN comp_text t ON t.entity_id = inst_edge.dst_id
            LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.id
            LEFT JOIN comp_user_known uk ON uk.entity_id = t.entity_id
            WHERE has_edge.src_id = ? AND has_edge.rel_type = 'has'
            ORDER BY LOWER(t.text_a) ASC
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [deckId, limit])
            return rows.map { row in
                CardListItem(
                    cardId: row["card_id"],
                    lemmaId: row["lemma_id"],
                    text: TextSanitizer.clean(row["text"], preserveLineBreaks: false) ?? "",
                    definition: TextSanitizer.clean(row["definition"], preserveLineBreaks: true),
                    dueAt: row["due_at"],
                    intervalDays: row["interval_days"],
                    reps: row["reps"],
                    mastery: row["mastery"],
                    seenCount: row["seen_count"] ?? 0)
            }
        }
    }

    /// Lemma 详情：词面 + 释义 + 词性 + 已定义同义词 + 出现过的生成文章。
    func lemmaDetail(_ lemmaId: EntityID, limit: Int = 20) throws -> LemmaDetail? {
        try database.dbWriter.read { db -> LemmaDetail? in
            // 1. 词面
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT t.text_a AS text, t.text_b AS definition, lm.pos AS pos
                FROM comp_text t
                LEFT JOIN comp_lemma_meta lm ON lm.entity_id = t.entity_id
                WHERE t.entity_id = ?
                """,
                arguments: [lemmaId])
            else { return nil }

            let text: String = TextSanitizer.clean(row["text"], preserveLineBreaks: false) ?? ""
            let definition: String? = TextSanitizer.clean(row["definition"], preserveLineBreaks: true)
            let pos: String? = row["pos"]

            // 2. 同义词（maps_to 双向）
            let synRows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    CASE WHEN e.src_id = ? THEN e.dst_id ELSE e.src_id END AS syn_id,
                    st.text_a AS syn_text,
                    COALESCE(ew.weight_double, 0.5) AS weight,
                    COALESCE(ew.source_type, 'manual') AS source_type
                FROM edges e
                LEFT JOIN comp_edge_weighted ew ON ew.entity_id = e.id
                LEFT JOIN comp_text st ON st.entity_id =
                    CASE WHEN e.src_id = ? THEN e.dst_id ELSE e.src_id END
                WHERE e.rel_type = 'maps_to' AND (e.src_id = ? OR e.dst_id = ?)
                """,
                arguments: [lemmaId, lemmaId, lemmaId, lemmaId])
            let synonyms = synRows.map { row in
                SynonymInfo(
                    lemmaId: row["syn_id"],
                    surfaceForm: row["syn_text"],
                    weight: row["weight"],
                    sourceType: row["source_type"])
            }

            // 3. 出现过的文章（lemma → article 的 highlighted_in/appears_in 边，
            //    article 在 dst 侧）
            let artRows = try Row.fetchAll(
                db,
                sql: """
                SELECT a.id AS article_id, a.created_at AS created_at,
                       t.text_a AS preview
                FROM edges e
                JOIN nodes a ON a.id = e.dst_id AND a.kind = 'article'
                JOIN comp_text t ON t.entity_id = a.id
                WHERE e.src_id = ? AND e.rel_type IN ('appears_in', 'highlighted_in')
                ORDER BY a.created_at DESC
                LIMIT ?
                """,
                arguments: [lemmaId, limit])
            let articles = artRows.map { row in
                ArticleHit(
                    articleId: row["article_id"],
                    preview: row["preview"] ?? "",
                    createdAt: row["created_at"])
            }

            return LemmaDetail(
                lemmaId: lemmaId, text: text, definition: definition,
                pos: pos, synonyms: synonyms, articles: articles)
        }
    }
}
