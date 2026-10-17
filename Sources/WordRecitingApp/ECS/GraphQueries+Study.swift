import GRDB
import Foundation

/// GraphQueries 扩展：背诵复习相关查询（到期队列 + 统计）。
/// @ai: 业务代码禁止手写 SQL，必须走 GraphQueries 的命名方法。
extension GraphQueries {

    /// 复习队列的「用户显式标记会」阈值：`mastery ≥ 该值` 不再进队列。
    static let dueMasteryCutoff = 1.999
    /// 复习队列的「模型高置信」阈值：`belief ≥ 该值` 不再进队列。
    /// @ai: 比 `WordMarkState.knownThreshold`（0.85）更保守——队列只收「明确不会 / 不确定」的词。
    ///      到期数（`studyStats.dueCount`）与队列（`dueCards`）必须共用这两个常量，禁止各写一份。
    static let dueBeliefCutoff = 0.90

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
    /// @ai: 概率主口径——模型认为已经会的词不再进队列；要复习需先改回不会。
    /// 每张卡附带词面（text_a/text_b）与 lemmaId，供闪卡 UI 使用。
    /// **行集与 `dueCount` / `queueDueDates` 严格一致**：三者共用 `dueQueueFrom` 的连接与谓词，
    /// 禁止各写一份（历史 bug：dueCards 用 INNER JOIN、dueCount 用 LEFT JOIN，
    /// CSV `front,back` 导入的卡片没有 instantiates 边 → UI 报「今日到期 N」但队列为空）。
    func dueCards(limit: Int = 100, now: Date = Date()) throws -> [CardListItem] {
        try database.dbWriter.read { db in
            let sql = """
            SELECT
                c.id            AS card_id,
                COALESCE(inst_edge.dst_id, c.id) AS lemma_id,
                COALESCE(lt.text_a, ct.text_a)   AS text,
                COALESCE(lt.text_b, ct.text_b)   AS definition,
                ss.due_at       AS due_at,
                ss.interval_days AS interval_days,
                ss.reps         AS reps,
                uk.mastery      AS mastery,
                uk.seen_count   AS seen_count,
                mb.belief       AS belief
            \(Self.dueQueueFrom)
              AND (ss.due_at IS NULL OR ss.due_at <= ?)
              AND (uk.mastery IS NULL OR uk.mastery < ?)
              AND (mb.belief IS NULL OR mb.belief < ?)
              AND COALESCE(lt.text_a, ct.text_a) IS NOT NULL
            -- 到期时间升序；同一时间用 card_id 兜底，保证队列顺序可复现（否则同 key 行序未定义）
            ORDER BY COALESCE(ss.due_at, '1970-01-01') ASC, c.id ASC
            LIMIT ?
            """
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: [now, Self.dueMasteryCutoff, Self.dueBeliefCutoff, limit])
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

    /// 到期队列的共享 FROM + 连接（三处查询唯一来源）。
    /// @ai: 用 LEFT JOIN 而非 INNER JOIN，使「无 instantiates 边的卡片」（CSV front/back 导入）
    ///      也能进队列——其词面直接取卡片自身的 comp_text。
    ///      `dueCount` / `queueDueDates` / `dueCards` 必须共同使用本常量，
    ///      否则又会出现「统计说 N 张到期、队列一张都不给」的口径分裂。
    ///      额外加 `COALESCE(...text_a) IS NOT NULL` 保证只收有词面的卡（无词面无法出题）。
    static let dueQueueFrom = """
    FROM nodes c
    LEFT JOIN edges inst_edge ON inst_edge.src_id = c.id AND inst_edge.rel_type = 'instantiates'
    LEFT JOIN comp_text lt ON lt.entity_id = inst_edge.dst_id
    LEFT JOIN comp_text ct ON ct.entity_id = c.id
    LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.id
    LEFT JOIN comp_user_known uk ON uk.entity_id = COALESCE(inst_edge.dst_id, c.id)
    LEFT JOIN comp_mastery_belief mb ON mb.entity_id = COALESCE(inst_edge.dst_id, c.id)
    WHERE c.kind = 'card'
    """

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
                    text: TextSanitizer.clean(row["text"], preserveLineBreaks: false) ?? "",
                    definition: TextSanitizer.clean(
                        row["definition"], preserveLineBreaks: true),
                    reviewCount: row["review_count"] ?? 0,
                    againCount: row["again_count"] ?? 0)
            }
        }
    }

    /// db 版本：全部复习评分明细（时间升序），供日快照 / 保留率 / 遗忘曲线 / 时段分布聚合。
    func allReviewRecords(_ db: Database) throws -> [ReviewRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT rated_at, rating, elapsed_days, last_ivl, factor FROM comp_review_event
            WHERE rated_at IS NOT NULL AND rating IS NOT NULL
            ORDER BY rated_at ASC, entity_id ASC
            """)
        return rows.map {
            ReviewRecord(ratedAt: $0["rated_at"], rating: $0["rating"],
                         elapsedDays: $0["elapsed_days"],
                         lastInterval: $0["last_ivl"], factor: $0["factor"])
        }
    }

    /// 便捷版本：自开读事务。
    func allReviewRecords() throws -> [ReviewRecord] {
        try database.dbWriter.read { db in try self.allReviewRecords(db) }
    }

    /// 复习队列内卡片的到期时间（nil = 新卡，视为立即到期），供负载预测。
    /// @ai: 排除口径与 `dueCards` 完全一致（共用 `dueQueueFrom`，显式标记会 / 模型高置信不进队列）。
    func queueDueDates() throws -> [Date?] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT ss.due_at \(Self.dueQueueFrom)
              AND (uk.mastery IS NULL OR uk.mastery < ?)
              AND (mb.belief IS NULL OR mb.belief < ?)
              AND COALESCE(lt.text_a, ct.text_a) IS NOT NULL
            """, arguments: [Self.dueMasteryCutoff, Self.dueBeliefCutoff])
            return rows.map { $0["due_at"] as Date? }
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
                SELECT COUNT(*) \(Self.dueQueueFrom)
                  AND (ss.due_at IS NULL OR ss.due_at <= ?)
                  AND (uk.mastery IS NULL OR uk.mastery < ?)
                  AND (mb.belief IS NULL OR mb.belief < ?)
                  AND COALESCE(lt.text_a, ct.text_a) IS NOT NULL
                """, arguments: [now, Self.dueMasteryCutoff, Self.dueBeliefCutoff]) ?? 0
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

/// 一次复习评分明细（保留率 / 评分分布 / 遗忘曲线 / 间隔与因子直方图 / 时段分布的输入）。
struct ReviewRecord: Sendable, Equatable {
    let ratedAt: Date
    let rating: Int
    /// 距上次复习的天数（首次复习为 0）。
    let elapsedDays: Double?
    /// 本次复习前卡片所处的间隔天数。
    let lastInterval: Double?
    /// 调度因子（简化 SM-2 的 factor）。
    let factor: Double?
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

    /// 平滑失败率 (again+1)/(reviews+2)：小样本不虚高，用于顽固词排序。
    var smoothedFailureRate: Double {
        Double(againCount + 1) / Double(reviewCount + 2)
    }
}
