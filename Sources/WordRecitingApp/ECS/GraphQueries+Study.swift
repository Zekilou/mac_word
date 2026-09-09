import GRDB
import Foundation

/// GraphQueries 扩展：背诵复习相关查询（到期队列 + 统计）。
/// @ai: 业务代码禁止手写 SQL，必须走 GraphQueries 的命名方法。
extension GraphQueries {

    /// 按 lemma 反查其卡片（Card 节点，instantiates 指向该 lemma）。
    /// 阅读区点击目标词评分时需要 cardId；未建卡返回 nil。
    func cardForLemma(_ lemmaId: EntityID) throws -> CardListItem? {
        try database.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: """
            SELECT
                c.id            AS card_id,
                t.entity_id     AS lemma_id,
                t.text_a        AS text,
                t.text_b        AS definition,
                ss.due_at       AS due_at,
                ss.interval_days AS interval_days,
                ss.reps         AS reps,
                uk.mastery      AS mastery,
                uk.seen_count   AS seen_count,
                mb.belief       AS belief
            FROM nodes c
            JOIN edges inst_edge ON inst_edge.src_id = c.id AND inst_edge.rel_type = 'instantiates'
            JOIN comp_text t ON t.entity_id = inst_edge.dst_id
            LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.id
            LEFT JOIN comp_user_known uk ON uk.entity_id = t.entity_id
            LEFT JOIN comp_mastery_belief mb ON mb.entity_id = t.entity_id
            WHERE c.kind = 'card' AND inst_edge.dst_id = ?
            ORDER BY c.created_at ASC
            LIMIT 1
            """, arguments: [lemmaId])
            guard let row else { return nil }
            return CardListItem(
                cardId: row["card_id"],
                lemmaId: row["lemma_id"],
                text: TextSanitizer.clean(row["text"], preserveLineBreaks: false) ?? "",
                definition: TextSanitizer.clean(row["definition"], preserveLineBreaks: true),
                dueAt: row["due_at"],
                intervalDays: row["interval_days"],
                reps: row["reps"],
                mastery: row["mastery"],
                seenCount: row["seen_count"] ?? 0,
                belief: row["belief"])
        }
    }

    /// 到期卡片队列（含从未学过的"新卡"）：按到期时间升序（最紧迫优先）。
    /// **排除**「用户显式标记会（mastery ≥ 1.999）」或「模型高置信（belief ≥ beliefCutoff）」的词。
    /// @ai: 概率主口径——模型认为已经会的词不再进背诵队列；要复习需先改回不会。
    /// 每张卡附带词面（text_a/text_b）与 lemmaId，供闪卡 UI 使用。
    func dueCards(limit: Int = 100, now: Date = Date()) throws -> [CardListItem] {
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
                uk.seen_count   AS seen_count,
                mb.belief       AS belief
            FROM nodes c
            JOIN edges inst_edge ON inst_edge.src_id = c.id AND inst_edge.rel_type = 'instantiates'
            JOIN comp_text t ON t.entity_id = inst_edge.dst_id
            LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.id
            LEFT JOIN comp_user_known uk ON uk.entity_id = t.entity_id
            LEFT JOIN comp_mastery_belief mb ON mb.entity_id = t.entity_id
            WHERE c.kind = 'card'
              AND (ss.due_at IS NULL OR ss.due_at <= ?)
              AND (uk.mastery IS NULL OR uk.mastery < ?)
              AND (mb.belief IS NULL OR mb.belief < ?)
            ORDER BY COALESCE(ss.due_at, '1970-01-01') ASC
            LIMIT ?
            """
            let knownCutoff = 1.999
            // 与 WordMarkState.knownThreshold 对齐的模型高置信阈值。
            let beliefCutoff = 0.90
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: [now, knownCutoff, beliefCutoff, limit])
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
                    seenCount: row["seen_count"] ?? 0,
                    belief: row["belief"])
            }
        }
    }

    /// 弱词排行：按 AGAIN 比例降序返回复习过的词（跨词库）。
    func weakLemmaDetails(limit: Int = 10, minReviews: Int = 1) throws -> [WeakLemmaStat] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT
                t.entity_id     AS lemma_id,
                t.text_a        AS text,
                t.text_b        AS definition,
                COUNT(*)        AS review_count,
                SUM(CASE WHEN rev.rating = 1 THEN 1 ELSE 0 END) AS again_count
            FROM edges prod_edge
            JOIN comp_review_event rev ON rev.entity_id = prod_edge.dst_id
            JOIN edges inst_edge
              ON inst_edge.src_id = prod_edge.src_id AND inst_edge.rel_type = 'instantiates'
            JOIN comp_text t ON t.entity_id = inst_edge.dst_id
            WHERE prod_edge.rel_type = 'produces'
            GROUP BY t.entity_id
            HAVING review_count >= ?
            ORDER BY (1.0 * again_count / review_count) DESC, review_count DESC
            LIMIT ?
            """, arguments: [minReviews, limit])
            return rows.map { row in
                WeakLemmaStat(
                    lemmaId: row["lemma_id"],
                    text: row["text"] ?? "",
                    definition: row["definition"],
                    reviewCount: row["review_count"] ?? 0,
                    againCount: row["again_count"] ?? 0)
            }
        }
    }

    /// 学习统计：总词数 / 已学 / 今日到期 / 今日已复习 / 总复习次数 / AGAIN 率。
    func studyStats(now: Date = Date()) throws -> StudyStats {
        try database.dbWriter.read { db in
            let totalCards = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM nodes WHERE kind = 'card'
                """) ?? 0
            let studiedCards = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_schedule_state WHERE reps > 0
                """) ?? 0
            let dueCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM nodes c
                LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.id
                LEFT JOIN edges inst_edge ON inst_edge.src_id = c.id AND inst_edge.rel_type = 'instantiates'
                LEFT JOIN comp_user_known uk ON uk.entity_id = inst_edge.dst_id
                WHERE c.kind = 'card' AND (ss.due_at IS NULL OR ss.due_at <= ?)
                  AND (uk.mastery IS NULL OR uk.mastery < ?)
                """, arguments: [now, 1.999]) ?? 0
            let todayStart = Calendar.current.startOfDay(for: now)
            let reviewedToday = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_review_event WHERE rated_at >= ?
                """, arguments: [todayStart]) ?? 0
            let totalReviews = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_review_event
                """) ?? 0
            let againCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_review_event WHERE rating = 1
                """) ?? 0
            let againRatio = totalReviews > 0 ? Double(againCount) / Double(totalReviews) : 0
            return StudyStats(
                totalCards: totalCards,
                studiedCards: studiedCards,
                dueCount: dueCount,
                reviewedToday: reviewedToday,
                totalReviews: totalReviews,
                againRatio: againRatio)
        }
    }
}

/// 学习统计快照。
struct StudyStats: Sendable, Equatable {
    let totalCards: Int
    let studiedCards: Int
    let dueCount: Int
    let reviewedToday: Int
    let totalReviews: Int
    let againRatio: Double
}

/// 弱词统计：一个词的学习表现。
struct WeakLemmaStat: Sendable, Equatable, Identifiable {
    var id: EntityID { lemmaId }
    let lemmaId: EntityID
    let text: String
    let definition: String?
    let reviewCount: Int
    let againCount: Int
    /// AGAIN 比例（0~1）。
    var againRatio: Double {
        reviewCount > 0 ? Double(againCount) / Double(reviewCount) : 0
    }
}
