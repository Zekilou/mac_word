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
}
