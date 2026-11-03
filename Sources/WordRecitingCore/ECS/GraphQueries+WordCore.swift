import Foundation
import GRDB

/// GraphQueries 扩展：**唯一**的「一个词」连接与映射。
///
/// @ai: 本文件回答一个问题——「词面 + 掌握度 + 概率 + 词频 + 事件聚合 + 排程」
///      该怎么 JOIN。答案只写一遍，所有列表查询都从这里取：
///
///        `recordedLemmas`  SELECT \(wordCoreColumns()) ... \(wordCoreFromByLemma)
///        `wordFeatures`    SELECT \(wordCoreColumns()) ... \(wordCoreFromByLemma)
///        `cardsInDeck`     SELECT \(wordCoreColumns()) ... \(wordCoreFromByCard)
///        `dueCards`        SELECT \(wordCoreColumns(…)) ... \(wordCoreFromByCard)
///
///      在此之前同一段连接被抄了 8 遍（belief 8 处、mastery/seen_count 4 处、
///      「卡片+词面+排程」3 遍），换口径要改 8 个地方，且已经出过事故
///      （`dueCards` 用 INNER JOIN 而 `dueCount` 用 LEFT JOIN → 「今日到期 N 张但队列为空」）。
///
///      两种行锚点，**不是两个口径**：
///        · `wordCoreFromByLemma`——「每个词一行」。词汇表、调度特征、同义词搜索用。
///        · `wordCoreFromByCard` ——「每张卡一行」。卡片浏览、背诵队列用。
///      一个词在 3 个词库里可以有 3 张卡，合并会把身份歧义渗到所有调用点，
///      所以只共用**词侧连接**（`wordCoreJoin` + `wordCoreColumns`），
///      行锚点各自声明一次。
public extension GraphQueries {

    // MARK: - 词侧连接（唯一来源）

    /// 词侧全部的 LEFT JOIN：词面 / 显式掌握度 / 后验概率 / 词频坐标 / 词事件聚合。
    /// @ai: 锚点是别名 `n`（词行）。两种行锚点都必须先把词行解析成 `n` 再拼这段，
    ///      这样 `belief` / `mastery` / `seen_count` 的全库只有一个 JOIN 位置。
    ///      全部 LEFT JOIN——缺任何一张组件表的词都要能出现在列表里（不是"有概率才有词"）。
    public static let wordCoreJoin = """
    LEFT JOIN comp_text t             ON t.entity_id = n.id
    LEFT JOIN comp_user_known k       ON k.entity_id = n.id
    LEFT JOIN comp_mastery_belief b   ON b.entity_id = n.id
    LEFT JOIN comp_lemma_frequency f  ON f.entity_id = n.id
    LEFT JOIN (
        SELECT lemma_id,
               COUNT(*)                  AS event_count,
               COUNT(DISTINCT region_id) AS context_count,
               MAX(occurred_at)          AS last_event_at
        FROM comp_word_event
        GROUP BY lemma_id
    ) ev ON ev.lemma_id = n.id
    """

    /// 词侧列清单（与 `wordCoreJoin` 配套，别名固定）。
    /// - Parameters:
    ///   - lemmaId: 词身份表达式。按卡一行时传 `COALESCE(n.id, c.id)`——
    ///     没有 `instantiates` 边的卡片以自身为词（CSV `front,back` 导入没有 lemma 节点）。
    ///   - textA/textB: 词面表达式。按卡一行时传 `COALESCE(t.text_a, ct.text_a)`，
    ///     保留「lemma 没词面就退回卡片自身词面」的历史兜底。
    public static func wordCoreColumns(
        lemmaId: String = "n.id",
        textA: String = "t.text_a",
        textB: String = "t.text_b"
    ) -> String {
        """
        \(lemmaId) AS lemma_id,
        \(textA) AS text_a,
        \(textB) AS text_b,
        k.mastery AS mastery,
        k.seen_count AS seen_count,
        k.updated_at AS updated_at,
        b.belief AS belief,
        f.band AS band,
        f.freq_rank AS freq_rank,
        COALESCE(ev.event_count, 0) AS event_count,
        COALESCE(ev.context_count, 0) AS context_count,
        ev.last_event_at AS last_event_at
        """
    }

    /// 排程列清单（与 `comp_schedule_state ss` 配套，别名固定）。
    public static let wordCoreScheduleColumns = """
    ss.due_at AS due_at,
    ss.interval_days AS interval_days,
    ss.reps AS reps,
    ss.lapses AS lapses,
    ss.last_reviewed_at AS last_reviewed_at
    """

    // MARK: - 行锚点 A：每个词一行

    /// 词 → 其「代表卡」（`MIN(card.id)`，与历史口径一致：一个 Lemma 只取一张卡）。
    /// @ai: 这里按 lemma 聚合，所以只能用于「每个词一行」的列表。
    ///      「每张卡一行」的列表必须用 `wordCoreFromByCard`，否则多卡词会丢卡。
    public static let wordCoreFromByLemma = """
    FROM nodes n
    \(wordCoreJoin)
    LEFT JOIN (
        SELECT inst.dst_id AS lemma_id, MIN(card.id) AS card_id
        FROM edges inst
        JOIN nodes card ON card.id = inst.src_id AND card.kind = 'card'
        WHERE inst.rel_type = 'instantiates'
        GROUP BY inst.dst_id
    ) c ON c.lemma_id = n.id
    LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.card_id
    WHERE n.kind = 'lemma'
    """

    /// 与 `wordCoreFromByLemma` 配套的完整列清单（含 schedule，行里多一列 `card_id`）。
    public static var wordCoreColumnsByLemma: String {
        """
        \(wordCoreColumns()),
        c.card_id AS card_id,
        \(wordCoreScheduleColumns)
        """
    }

    // MARK: - 行锚点 B：每张卡一行

    /// **到期队列与卡片浏览的唯一 FROM**：卡 → 词（`instantiates`），无边的卡退回自身。
    /// @ai: 用 LEFT JOIN 而非 INNER JOIN，使 CSV `front,back` 导入的卡片（没有 lemma 节点、
    ///      也没有 instantiates 边）也能进队列——其词面与掌握度直接取卡片自身的组件。
    ///      `dueCards` / `queueDueDates` / `studyStats.dueCount` / `cardsInDeck` 全部基于它，
    ///      否则又会出现「统计说 N 张到期、队列一张都不给」的口径分裂。
    ///      额外要求词面非空（无词面的卡无法出题）由调用方追加。
    public static let wordCoreFromByCard = """
    FROM nodes c
    LEFT JOIN edges inst_edge ON inst_edge.src_id = c.id AND inst_edge.rel_type = 'instantiates'
    LEFT JOIN nodes n ON n.id = COALESCE(inst_edge.dst_id, c.id)
    LEFT JOIN comp_text ct ON ct.entity_id = c.id
    \(wordCoreJoin)
    LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.id
    WHERE c.kind = 'card'
    """

    /// 与 `wordCoreFromByCard` 配套的完整列清单。
    public static var wordCoreColumnsByCard: String {
        """
        \(wordCoreColumns(
            lemmaId: "COALESCE(n.id, c.id)",
            textA: "COALESCE(t.text_a, ct.text_a)",
            textB: "COALESCE(t.text_b, ct.text_b)")),
        c.id AS card_id,
        \(wordCoreScheduleColumns)
        """
    }

    // MARK: - 映射（唯一来源）

    /// 一行 → `WordCore`（词身份由 SQL 的 `lemma_id` 决定）。
    /// @ai: 词面/释义必须过 `TextSanitizer.clean`——存量库里还有 Anki HTML 残留，
    ///      查询层是最后一道兜底（v7/v8/v9 迁移只洗了存量，新脏数据仍可能来自第三方导入）。
    public static func makeWordCore(_ row: Row) -> WordCore {
        let cardId: EntityID? = row["card_id"]
        return WordCore(
            lemmaId: row["lemma_id"],
            text: TextSanitizer.clean(row["text_a"], preserveLineBreaks: false) ?? "",
            definition: TextSanitizer.clean(row["text_b"], preserveLineBreaks: true),
            mastery: row["mastery"],
            belief: row["belief"],
            band: row["band"],
            rank: row["freq_rank"],
            seenCount: row["seen_count"] ?? 0,
            eventCount: row["event_count"] ?? 0,
            contextCount: row["context_count"] ?? 0,
            lastEventAt: row["last_event_at"],
            updatedAt: row["updated_at"],
            schedule: cardId.map { id in
                WordCore.CardSchedule(
                    cardId: id,
                    dueAt: row["due_at"],
                    intervalDays: row["interval_days"],
                    reps: row["reps"] ?? 0,
                    lapses: row["lapses"] ?? 0,
                    lastReviewedAt: row["last_reviewed_at"])
            })
    }

    /// 一行 → `WordCore.Card`（卡片身份取 SQL 的 `card_id`）。
    public static func makeWordCard(_ row: Row) -> WordCore.Card {
        let core = makeWordCore(row)
        let cardId: EntityID? = row["card_id"]
        return WordCore.Card(cardId: cardId ?? core.lemmaId, word: core)
    }

    /// 单行查询：按 lemma 取一个词快照（详情页 / 单卡反查用）。
    public func wordCore(_ db: Database, lemmaId: EntityID) throws -> WordCore? {
        try Row.fetchOne(db, sql: """
            SELECT \(Self.wordCoreColumnsByLemma)
            \(Self.wordCoreFromByLemma)
              AND n.id = ?
            """, arguments: [lemmaId])
            .map(Self.makeWordCore)
    }

    /// 便捷版本：自开读事务。
    public func wordCore(lemmaId: EntityID) throws -> WordCore? {
        try database.dbWriter.read { db in try self.wordCore(db, lemmaId: lemmaId) }
    }
}
