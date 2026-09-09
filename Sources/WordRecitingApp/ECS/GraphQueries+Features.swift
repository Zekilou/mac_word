import Foundation
import GRDB

/// GraphQueries 扩展：词元特征批量查询（调度策略的数据来源）。
/// @ai: 一次 SQL 拿全；N 个词不产生 N 次查询。业务代码禁止手写 SQL，走这里。
extension GraphQueries {

    /// db 版本：批量取词元特征（复用外层事务）。
    func wordFeatures(_ db: Database, lemmaIds: [EntityID]) throws -> [EntityID: WordFeatures] {
        guard !lemmaIds.isEmpty else { return [:] }
        let placeholders = databaseQuestionMarks(count: lemmaIds.count)
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                n.id                          AS lemma_id,
                b.belief                      AS belief,
                f.band                        AS band,
                f.freq_rank                   AS freq_rank,
                COALESCE(ev.event_count, 0)   AS event_count,
                COALESCE(ev.context_count, 0) AS context_count,
                ev.last_event_at              AS last_event_at,
                c.card_id                     AS card_id,
                ss.due_at                     AS due_at,
                ss.reps                       AS reps,
                ss.lapses                     AS lapses,
                ss.interval_days              AS interval_days,
                ss.last_reviewed_at           AS last_reviewed_at
            FROM nodes n
            LEFT JOIN comp_mastery_belief  b ON b.entity_id = n.id
            LEFT JOIN comp_lemma_frequency f ON f.entity_id = n.id
            LEFT JOIN (
                SELECT lemma_id,
                       COUNT(*)                  AS event_count,
                       COUNT(DISTINCT region_id) AS context_count,
                       MAX(occurred_at)          AS last_event_at
                FROM comp_word_event
                GROUP BY lemma_id
            ) ev ON ev.lemma_id = n.id
            LEFT JOIN (
                SELECT inst.dst_id AS lemma_id, MIN(card.id) AS card_id
                FROM edges inst
                JOIN nodes card ON card.id = inst.src_id AND card.kind = 'card'
                WHERE inst.rel_type = 'instantiates'
                GROUP BY inst.dst_id
            ) c ON c.lemma_id = n.id
            LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.card_id
            WHERE n.kind = 'lemma' AND n.id IN (\(placeholders))
            """, arguments: StatementArguments(lemmaIds))
        return Self.mapFeatures(rows)
    }

    /// 便捷版本：自开读事务。
    func wordFeatures(lemmaIds: [EntityID]) throws -> [EntityID: WordFeatures] {
        try database.dbWriter.read { db in
            try self.wordFeatures(db, lemmaIds: lemmaIds)
        }
    }

    /// db 版本：全部 Lemma 的特征。
    func allWordFeatures(_ db: Database) throws -> [EntityID: WordFeatures] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                n.id                          AS lemma_id,
                b.belief                      AS belief,
                f.band                        AS band,
                f.freq_rank                   AS freq_rank,
                COALESCE(ev.event_count, 0)   AS event_count,
                COALESCE(ev.context_count, 0) AS context_count,
                ev.last_event_at              AS last_event_at,
                c.card_id                     AS card_id,
                ss.due_at                     AS due_at,
                ss.reps                       AS reps,
                ss.lapses                     AS lapses,
                ss.interval_days              AS interval_days,
                ss.last_reviewed_at           AS last_reviewed_at
            FROM nodes n
            LEFT JOIN comp_mastery_belief  b ON b.entity_id = n.id
            LEFT JOIN comp_lemma_frequency f ON f.entity_id = n.id
            LEFT JOIN (
                SELECT lemma_id,
                       COUNT(*)                  AS event_count,
                       COUNT(DISTINCT region_id) AS context_count,
                       MAX(occurred_at)          AS last_event_at
                FROM comp_word_event
                GROUP BY lemma_id
            ) ev ON ev.lemma_id = n.id
            LEFT JOIN (
                SELECT inst.dst_id AS lemma_id, MIN(card.id) AS card_id
                FROM edges inst
                JOIN nodes card ON card.id = inst.src_id AND card.kind = 'card'
                WHERE inst.rel_type = 'instantiates'
                GROUP BY inst.dst_id
            ) c ON c.lemma_id = n.id
            LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.card_id
            WHERE n.kind = 'lemma'
            """)
        return Self.mapFeatures(rows)
    }

    /// 便捷版本：自开读事务。
    func allWordFeatures() throws -> [EntityID: WordFeatures] {
        try database.dbWriter.read { db in
            try self.allWordFeatures(db)
        }
    }

    /// db 版本：卡片对应的词元（instantiates 边）。
    func lemmaIdForCard(_ db: Database, cardId: EntityID) throws -> EntityID? {
        try String.fetchOne(db, sql: """
            SELECT dst_id FROM edges
            WHERE src_id = ? AND rel_type = 'instantiates'
            LIMIT 1
            """, arguments: [cardId])
    }

    private static func mapFeatures(_ rows: [Row]) -> [EntityID: WordFeatures] {
        var result: [EntityID: WordFeatures] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let lemmaId: EntityID = row["lemma_id"]
            let cardId: EntityID? = row["card_id"]
            result[lemmaId] = WordFeatures(
                lemmaId: lemmaId,
                belief: row["belief"],
                band: row["band"],
                rank: row["freq_rank"],
                eventCount: row["event_count"] ?? 0,
                contextCount: row["context_count"] ?? 0,
                lastEventAt: row["last_event_at"],
                card: cardId.map { id in
                    WordFeatures.CardSchedule(
                        cardId: id,
                        dueAt: row["due_at"],
                        reps: row["reps"] ?? 0,
                        lapses: row["lapses"] ?? 0,
                        intervalDays: row["interval_days"],
                        lastReviewedAt: row["last_reviewed_at"])
                })
        }
        return result
    }
}
