import GRDB
import Foundation

/// GraphQueries 扩展：Deck 内卡片浏览 + Lemma 详情。
/// @ai: 业务代码禁止手写 SQL，必须走 GraphQueries 的命名方法。
extension GraphQueries {

    /// 返回某 deck 下的所有卡片（Card 节点 + 关联 Lemma 词面 + 复习状态），
    /// 按单词字母序排序。
    public func cardsInDeck(_ deckId: EntityID, limit: Int = 5000) throws -> [CardListItem] {
        try database.dbWriter.read { db in
            // @ai: 复用 `wordCoreColumnsByCard` / `wordCoreFromByCard`（唯一词侧连接），
            //      只额外加一个「属于该词库」的 has 边过滤。
            //      这样卡片行自带 band / rank / updatedAt / schedule，卡片浏览页的筛选维度
            //      与词列表完全一致（以前这里手写 9 列，band 等字段根本没查）。
            let sql = """
            SELECT \(Self.wordCoreColumnsByCard)
            \(Self.wordCoreFromByCard)
              AND EXISTS (
                  SELECT 1 FROM edges has_edge
                  WHERE has_edge.src_id = ? AND has_edge.dst_id = c.id
                    AND has_edge.rel_type = 'has'
              )
              AND COALESCE(t.text_a, ct.text_a) IS NOT NULL
            ORDER BY LOWER(COALESCE(t.text_a, ct.text_a)) ASC, c.id ASC
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [deckId, limit])
            return rows.map { row in
                CardListItem(cardId: row["card_id"], word: Self.makeWordCore(row))
            }
        }
    }

    /// Lemma 详情：词面 + 释义 + 词性 + 已定义同义词 + 出现过的生成文章。
    public func lemmaDetail(_ lemmaId: EntityID, limit: Int = 20) throws -> LemmaDetail? {
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
