import GRDB
import Foundation

/// GraphQueries 扩展：用户词汇掌握度（全局上下文）查询。
/// @ai: 业务代码禁止手写 SQL，必须走本扩展的命名方法。
extension GraphQueries {

    // MARK: - 1. 全部已知词掌握度

    /// 返回所有有掌握度记录的 Lemma → mastery。
    /// **值域**：0 = 无记录（显式）；1 = 不会；2 = 会；1~2 连续渐变。
    /// @ai: 初始化回看 / 覆盖率统计用；10 万词级全表扫描可控（单表小）。
    func knownLemmaMastery() throws -> [EntityID: Double] {
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
    func lemmaMastery(lemmaId: EntityID) throws -> Double? {
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
    func allLemmaSeenCounts() throws -> [EntityID: Int] {
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
    struct MasteryOverview: Sendable, Equatable {
        var known: Int
        var unknown: Int
        var seen: Int
        var unmarked: Int
    }

    /// 全局掌握度统计：已标记会（mastery ≥ 1.5）/ 已标记不会（1 ≤ mastery < 1.5）/
    /// 出现过未确认（mastery ≤ 0 且 seen_count > 0）/ 未标记（无行或全 0）。
    func masteryOverview() throws -> MasteryOverview {
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
    struct RecordedLemma: Identifiable, Sendable, Equatable {
        var id: EntityID { lemmaID }
        let lemmaID: EntityID
        /// 词面（text_a，可能带音标尾巴；显示时用 WordNormalizer.clean 清洗）。
        let text: String
        /// 主释义（text_b，可空）。
        let definition: String?
        /// 掌握度（0 = 仅 seen 记录）。
        let mastery: Double
        /// 出现过次数。
        let seenCount: Int
        /// 最近写入来源（init / rss 等）。
        let source: String?
        let updatedAt: Date?
    }

    /// 所有有记录的词（mastery > 0 或 seen_count > 0），按最近更新倒序。
    /// @ai: 状态派生统一走 WordMarkState.from(mastery:seenCount:)，保证与词块显示口径一致。
    func recordedLemmas() throws -> [RecordedLemma] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT k.entity_id, t.text_a AS text, t.text_b AS definition,
                       k.mastery, k.seen_count, k.source, k.updated_at
                FROM comp_user_known k
                LEFT JOIN comp_text t ON t.entity_id = k.entity_id
                WHERE k.mastery > 0 OR k.seen_count > 0
                ORDER BY k.updated_at DESC, k.entity_id DESC
                """)
            return rows.map { row in
                RecordedLemma(
                    lemmaID: row["entity_id"],
                    text: TextSanitizer.clean(row["text"], preserveLineBreaks: false) ?? "",
                    definition: TextSanitizer.clean(row["definition"], preserveLineBreaks: true),
                    mastery: row["mastery"],
                    seenCount: row["seen_count"],
                    source: row["source"],
                    updatedAt: row["updated_at"])
            }
        }
    }
}
