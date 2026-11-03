import GRDB
import Foundation

/// GraphQueries 扩展：用户词汇掌握度（全局上下文）查询。
/// @ai: 业务代码禁止手写 SQL，必须走本扩展的命名方法。
extension GraphQueries {

    // MARK: - 1. 全部已知词掌握度

    /// 返回所有有掌握度记录的 Lemma → mastery。
    /// **值域**：0 = 无记录（显式）；1 = 不会；2 = 会；1~2 连续渐变。
    /// @ai: 初始化回看 / 覆盖率统计用；10 万词级全表扫描可控（单表小）。
    public func knownLemmaMastery() throws -> [EntityID: Double] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, mastery FROM comp_user_known
                """)
            var result: [EntityID: Double] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                result[row["entity_id"]] = row["mastery"]
            }
            return result
        }
    }

    // MARK: - 2. 单个 Lemma 掌握度

    /// 便捷版本（自开读事务）。
    public func lemmaMastery(lemmaId: EntityID) throws -> Double? {
        try database.dbWriter.read { db in
            try lemmaMastery(db, lemmaId: lemmaId)
        }
    }

    /// db 版本（System 事务内复用）。无记录返回 nil。
    func lemmaMastery(_ db: Database, lemmaId: EntityID) throws -> Double? {
        try Double.fetchOne(db, sql: """
            SELECT mastery FROM comp_user_known WHERE entity_id = ?
            """, arguments: [lemmaId])
    }

    // MARK: - 3. 多来源释义

    /// 返回某 Lemma 的多来源释义条目（comp_lemma_definitions），无记录返回空数组。
    func lemmaDefinitions(lemmaId: EntityID) throws -> [DefinitionEntry] {
        try database.dbWriter.read { db in
            let json = try String.fetchOne(db, sql: """
                SELECT definitions_json FROM comp_lemma_definitions WHERE entity_id = ?
                """, arguments: [lemmaId])
            guard let json else { return [] }
            return (try? JSONDecoder().decode(
                [DefinitionEntry].self, from: Data(json.utf8))) ?? []
        }
    }

    // MARK: - 3.5 出现过（seen）

    /// 返回所有有 seen 记录的 Lemma → 出现次数（RSS 等阅读文本自动记录）。
    /// @ai: mastery <= 0 且 seen > 0 = 出现过未确认；有 mastery 的 seen 仅作频次参考。
    public func allLemmaSeenCounts() throws -> [EntityID: Int] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, seen_count FROM comp_user_known
                WHERE seen_count > 0
                """)
            var result: [EntityID: Int] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                result[row["entity_id"]] = row["seen_count"]
            }
            return result
        }
    }

    // MARK: - 4. 掌握度概览（供初始化 / 分析用）

    /// 返回已标记会 / 不会 / 出现过（未确认）/ 未标记 四组计数。
    public struct MasteryOverview: Sendable, Equatable {
        public var known: Int
        public var unknown: Int
        public var seen: Int
        public var unmarked: Int

        public init(known: Int, unknown: Int, seen: Int, unmarked: Int) {
            self.known = known
            self.unknown = unknown
            self.seen = seen
            self.unmarked = unmarked
        }
    }

    /// 全局掌握度统计：已标记会（mastery ≥ 1.5）/ 已标记不会（1 ≤ mastery < 1.5）/
    /// 出现过未确认（mastery ≤ 0 且 seen_count > 0）/ 未标记（无行或全 0）。
    public func masteryOverview() throws -> MasteryOverview {
        try database.dbWriter.read { db in
            let known = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_user_known WHERE mastery >= 1.5
                """) ?? 0
            let unknown = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_user_known
                WHERE mastery >= 1.0 AND mastery < 1.5
                """) ?? 0
            let seen = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_user_known
                WHERE mastery <= 0 AND seen_count > 0
                """) ?? 0
            let allLemmas = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'
                """) ?? 0
            return MasteryOverview(
                known: known, unknown: unknown, seen: seen,
                unmarked: max(0, allLemmas - known - unknown - seen))
        }
    }

    // MARK: - 5. 已记录词汇表（词表浏览）

    /// 已记录词元条目（有掌握度或出现过记录）。
    /// 词汇表行：**完整词快照 + 词表专有的 `source`**。
    ///
    /// @ai: 与 `CardListItem` 同款收敛——内部只持有 `WordCore`，词频带 `band`/`rank`、
    ///      代表卡的 `schedule` 都随快照一起过来，所以词汇表现在可以按词频带与到期筛。
    ///      旧属性名全部保留为转发计算属性，UI 与测试无需改动。
    public struct RecordedLemma: Identifiable, Sendable, Equatable {
        public var id: EntityID { word.lemmaId }

        /// 完整词快照（唯一数据来源）。
        public let word: WordCore
        /// 最近写入来源（init / rss 等）——词汇表专有，不在 WordCore 里。
        public let source: String?

        public init(word: WordCore, source: String?) {
            self.word = word
            self.source = source
        }

        // MARK: 转发到 word

        public var lemmaID: EntityID { word.lemmaId }
        public var text: String { word.text }
        public var definition: String? { word.definition }
        /// 掌握度：WordCore 用 nil 表示「无记录」，旧口径用 0，这里保持旧语义。
        public var mastery: Double { word.mastery ?? 0 }
        public var seenCount: Int { word.seenCount }
        public var updatedAt: Date? { word.updatedAt }
        public var belief: Double? { word.belief }
        public var contextCount: Int { word.contextCount }
        public var eventCount: Int { word.eventCount }
        /// 词频带 1..25；nil = 表外。**本轮新增**（以前词汇表没有这一列）。
        public var band: Int? { word.band }
        /// 全表排名。**本轮新增**。
        public var rank: Int? { word.rank }
        /// 该词代表卡的排程（nil = 没有卡）。**本轮新增**。
        public var schedule: WordCore.CardSchedule? { word.schedule }

        /// 过渡构造器（测试与旧调用点用）。
        /// @ai: 新代码应直接用 `RecordedLemma(word:source:)`，否则新增字段会在构造时丢掉。
        public init(
            lemmaID: EntityID, text: String, definition: String?, mastery: Double,
            seenCount: Int, source: String?, updatedAt: Date?, belief: Double?,
            contextCount: Int, eventCount: Int
        ) {
            self.init(word: WordCore(
                lemmaId: lemmaID, text: text, definition: definition,
                mastery: mastery > 0 ? mastery : nil, belief: belief,
                seenCount: seenCount, eventCount: eventCount,
                contextCount: contextCount, updatedAt: updatedAt),
                source: source)
        }
    }

    /// 所有有记录的词（mastery > 0 或 seen_count > 0），按最近更新倒序。
    /// @ai: 状态派生统一走 WordMarkState.from(belief:mastery:seenCount:)，保证与词块显示口径一致。
    public func recordedLemmas() throws -> [RecordedLemma] {
        try database.dbWriter.read { db in
            // @ai: 复用 `wordCoreColumnsByLemma` / `wordCoreFromByLemma`（唯一词侧连接）——
            //      以前这里手写 JOIN + 两个相关子查询，词频带与代表卡排程根本没查，
            //      所以词汇表只能禁用 .band / .due 两个筛选维度。
            //      额外多查一列 `k.source`（词汇表专有）。
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Self.wordCoreColumnsByLemma),
                       k.source AS source
                \(Self.wordCoreFromByLemma)
                  AND (k.mastery > 0 OR k.seen_count > 0)
                ORDER BY k.updated_at DESC, n.id DESC
                """)
            return rows.map { row in
                RecordedLemma(word: Self.makeWordCore(row), source: row["source"])
            }
        }
    }
}
