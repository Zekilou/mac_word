import Foundation
import GRDB

/// GraphQueries 扩展：BKT 后验掌握度概率查询。
/// @ai: 业务代码禁止手写 SQL，必须走本扩展的命名方法。
extension GraphQueries {

    /// db 版本（System 事务内复用）。无记录返回 nil。
    func masteryBelief(_ db: Database, lemmaId: EntityID) throws -> Double? {
        try Double.fetchOne(db, sql: """
            SELECT belief FROM comp_mastery_belief WHERE entity_id = ?
            """, arguments: [lemmaId])
    }

    /// 便捷版本（自开读事务）。
    func masteryBelief(lemmaId: EntityID) throws -> Double? {
        try database.dbWriter.read { db in
            try self.masteryBelief(db, lemmaId: lemmaId)
        }
    }

    /// 全部后验（批量，供列表展示）。
    func allMasteryBeliefs() throws -> [EntityID: Double] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, belief FROM comp_mastery_belief
                """)
            var result: [EntityID: Double] = [:]
            result.reserveCapacity(rows.count)
            for row in rows { result[row["entity_id"]] = row["belief"] }
            return result
        }
    }

    // MARK: - 分布与词频带聚合

    /// 概率档位分布（阈值由调用方传入，避免 ECS 依赖 UI 常量）。
    struct MasteryDistribution: Sendable, Equatable {
        var known: Int
        var unknown: Int
        var learning: Int
        var total: Int
    }

    func masteryDistribution(knownThreshold: Double,
                             unknownThreshold: Double) throws -> MasteryDistribution {
        try database.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    SUM(CASE WHEN belief >= ? THEN 1 ELSE 0 END) AS known,
                    SUM(CASE WHEN belief <= ? THEN 1 ELSE 0 END) AS unknown,
                    SUM(CASE WHEN belief > ? AND belief < ? THEN 1 ELSE 0 END) AS learning,
                    COUNT(*) AS total
                FROM comp_mastery_belief
                """, arguments: [knownThreshold, unknownThreshold,
                                 unknownThreshold, knownThreshold])
            return MasteryDistribution(
                known: row?["known"] ?? 0,
                unknown: row?["unknown"] ?? 0,
                learning: row?["learning"] ?? 0,
                total: row?["total"] ?? 0)
        }
    }

    /// 按词频带聚合已观测词的后验（band → 观测数 + 后验之和）。
    func masteryByBand() throws -> [BandStat] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.band AS band,
                       COUNT(b.entity_id) AS observed_count,
                       COALESCE(SUM(b.belief), 0) AS sum_belief
                FROM comp_lemma_frequency f
                LEFT JOIN comp_mastery_belief b ON b.entity_id = f.entity_id
                GROUP BY f.band
                ORDER BY f.band ASC
                """)
            return rows.map { row in
                BandStat(band: row["band"],
                         observedCount: row["observed_count"],
                         sumBelief: row["sum_belief"])
            }
        }
    }
}
