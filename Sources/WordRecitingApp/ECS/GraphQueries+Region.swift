import Foundation
import GRDB

/// GraphQueries 扩展：region / 词事件 / 词频坐标查询。
/// @ai: 业务代码禁止手写 SQL，必须走本扩展的命名方法。
extension GraphQueries {

    /// 一条词事件（时间倒序返回）。
    struct WordEventRow: Sendable, Equatable, Identifiable {
        var id: EntityID { eventId }
        let eventId: EntityID
        let lemmaId: EntityID
        let regionId: EntityID
        /// WordEventKind.rawValue。
        let kind: String
        let trust: Double
        let occurredAt: Date
    }

    /// 一个词汇显示上下文。
    struct RegionRow: Sendable, Equatable, Identifiable {
        var id: EntityID { regionId }
        let regionId: EntityID
        /// RegionKind.rawValue。
        let kind: String
        let label: String?
        let sourceId: EntityID?
        let trust: Double
        let createdAt: Date
    }

    /// 词频族坐标。
    struct LemmaFrequencyRow: Sendable, Equatable {
        let band: Int
        let freqRank: Int
        let source: String
    }

    // MARK: - 词事件

    /// db 版本：复用外层事务（System 内必须用这个）。`ascending = true` 按时间升序（重放用）。
    func wordEvents(_ db: Database, lemmaId: EntityID,
                    ascending: Bool = true, limit: Int = 5000) throws -> [WordEventRow] {
        let order = ascending ? "ASC" : "DESC"
        let rows = try Row.fetchAll(db, sql: """
            SELECT entity_id, lemma_id, region_id, event_kind, trust, occurred_at
            FROM comp_word_event
            WHERE lemma_id = ?
            ORDER BY occurred_at \(order), entity_id \(order)
            LIMIT ?
            """, arguments: [lemmaId, limit])
        return rows.map(Self.makeEventRow)
    }

    /// 便捷版本：自开读事务，时间倒序。
    func wordEvents(lemmaId: EntityID, limit: Int = 500) throws -> [WordEventRow] {
        try database.dbWriter.read { db in
            try self.wordEvents(db, lemmaId: lemmaId, ascending: false, limit: limit)
        }
    }

    /// 某 Region 内的全部词事件（时间倒序）。
    func wordEvents(regionId: EntityID, limit: Int = 500) throws -> [WordEventRow] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, lemma_id, region_id, event_kind, trust, occurred_at
                FROM comp_word_event
                WHERE region_id = ?
                ORDER BY occurred_at DESC, entity_id DESC
                LIMIT ?
                """, arguments: [regionId, limit])
            return rows.map(Self.makeEventRow)
        }
    }

    /// 某 Lemma 的事件总数。
    func wordEventCount(lemmaId: EntityID) throws -> Int {
        try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_word_event WHERE lemma_id = ?",
                             arguments: [lemmaId]) ?? 0
        }
    }

    /// 某 Lemma 按事件种类分组计数（后续 BKT / CD 建模的输入）。
    func wordEventCountsByKind(lemmaId: EntityID) throws -> [String: Int] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT event_kind, COUNT(*) AS n
                FROM comp_word_event
                WHERE lemma_id = ?
                GROUP BY event_kind
                """, arguments: [lemmaId])
            var result: [String: Int] = [:]
            for row in rows { result[row["event_kind"]] = row["n"] }
            return result
        }
    }

    /// db 版本：某 Lemma 出现在多少个不同 region。
    func distinctRegionCount(_ db: Database, lemmaId: EntityID) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT region_id) FROM comp_word_event WHERE lemma_id = ?
            """, arguments: [lemmaId]) ?? 0
    }

    /// 便捷版本：自开读事务。
    func distinctRegionCount(lemmaId: EntityID) throws -> Int {
        try database.dbWriter.read { db in
            try self.distinctRegionCount(db, lemmaId: lemmaId)
        }
    }

    // MARK: - Region

    func region(regionId: EntityID) throws -> RegionRow? {
        try database.dbWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT entity_id, kind, label, source_id, trust, created_at
                FROM comp_region
                WHERE entity_id = ?
                """, arguments: [regionId]) else { return nil }
            return RegionRow(regionId: row["entity_id"], kind: row["kind"], label: row["label"],
                             sourceId: row["source_id"], trust: row["trust"],
                             createdAt: row["created_at"])
        }
    }

    // MARK: - 词频坐标

    /// db 版本：某 Lemma 的词频坐标。
    func lemmaFrequency(_ db: Database, lemmaId: EntityID) throws -> LemmaFrequencyRow? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT band, freq_rank, source FROM comp_lemma_frequency WHERE entity_id = ?
            """, arguments: [lemmaId]) else { return nil }
        return LemmaFrequencyRow(band: row["band"], freqRank: row["freq_rank"],
                                 source: row["source"])
    }

    /// 便捷版本：自开读事务。
    func lemmaFrequency(lemmaId: EntityID) throws -> LemmaFrequencyRow? {
        try database.dbWriter.read { db in
            try self.lemmaFrequency(db, lemmaId: lemmaId)
        }
    }

    /// 全部词频坐标（批量，供列表展示）。
    func allLemmaFrequencies() throws -> [EntityID: LemmaFrequencyRow] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, band, freq_rank, source FROM comp_lemma_frequency
                """)
            var result: [EntityID: LemmaFrequencyRow] = [:]
            for row in rows {
                result[row["entity_id"]] = LemmaFrequencyRow(
                    band: row["band"], freqRank: row["freq_rank"], source: row["source"])
            }
            return result
        }
    }

    private static func makeEventRow(_ row: Row) -> WordEventRow {
        WordEventRow(eventId: row["entity_id"], lemmaId: row["lemma_id"],
                     regionId: row["region_id"], kind: row["event_kind"],
                     trust: row["trust"], occurredAt: row["occurred_at"])
    }
}
