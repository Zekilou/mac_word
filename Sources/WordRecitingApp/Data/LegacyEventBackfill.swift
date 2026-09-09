import Foundation
import GRDB

/// v6 一次性数据迁移：把 v4 之前产生的词汇记录（`comp_user_known` 的 mastery / seen_count）
/// 合成为词事件流（`comp_word_event`），让 BKT 后验对历史数据也有值。
/// @ai: 事件挂在专用 region（`RegionKind.legacy`）下，可按 region 回滚；id 确定，重复执行幂等；
///      后验由启动时的 `VocabularyMaintenance.backfillMastery` 重算（本迁移只写事件，不算概率）。
enum LegacyEventBackfill {

    /// 专用 region id（回滚时按它 + 事件 id 前缀删除）。
    static let regionId = "region-legacy-backfill"
    /// 事件节点 id 前缀（回滚用）。
    static let eventIdPrefix = "legacy-we-"
    /// 事件 detail 标记，便于识别来源。
    static let detailJson = "{\"source\":\"legacy_backfill\"}"

    /// 执行一次性回填（由迁移 `v6_legacy_event_backfill` 调用）。
    static func run(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT entity_id, mastery, seen_count, updated_at FROM comp_user_known
            """)
        guard !rows.isEmpty else { return }

        let now = Date()
        try db.execute(sql: """
            INSERT OR IGNORE INTO nodes (id, kind, created_at) VALUES (?, 'region', ?)
            """, arguments: [regionId, now])
        try db.execute(sql: """
            INSERT OR REPLACE INTO comp_region
                (entity_id, kind, label, source_id, trust, created_at)
            VALUES (?, ?, '旧数据迁移', NULL, 1.0, ?)
            """, arguments: [regionId, RegionKind.legacy.rawValue, now])

        for row in rows {
            let lemmaId: String = row["entity_id"]
            let mastery: Double = row["mastery"]
            let seenCount: Int = row["seen_count"]
            let updatedAt: Date = row["updated_at"]

            // 被动出现（低可信）：显式标记之前发生（只有单条 updated_at，用 -1s 表达先后）。
            if seenCount > 0 {
                let occurredAt = mastery > 0 ? updatedAt.addingTimeInterval(-1) : updatedAt
                try insertEvent(db, lemmaId: lemmaId, kind: .seen, trust: 0.0,
                                occurredAt: occurredAt, now: now)
            }
            // 显式标记（高可信）：2=会 / 1=不会；中间值用 trust 表达"半会"。
            if mastery >= 1.999 {
                try insertEvent(db, lemmaId: lemmaId, kind: .markKnown, trust: 1.0,
                                occurredAt: updatedAt, now: now)
            } else if mastery > 0, mastery <= 1.001 {
                try insertEvent(db, lemmaId: lemmaId, kind: .markUnknown, trust: 1.0,
                                occurredAt: updatedAt, now: now)
            } else if mastery > 1.001, mastery < 1.999 {
                try insertEvent(db, lemmaId: lemmaId, kind: .markKnown, trust: mastery - 1.0,
                                occurredAt: updatedAt, now: now)
            }
        }
    }

    /// 回滚：删除本迁移写入的事件与 region（幂等；删事件节点会级联清掉边与组件行）。
    static func rollback(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM nodes WHERE id LIKE ?",
                       arguments: ["\(eventIdPrefix)%"])
        try db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [regionId])
    }

    /// 写一个事件：节点 + 组件 + produces / contains 两条边（与 `RegionSystem` 约定一致；
    /// 边本身也是节点，`edges.id` 外键指向 `nodes.id`）。
    private static func insertEvent(_ db: Database, lemmaId: String, kind: WordEventKind,
                                    trust: Double, occurredAt: Date, now: Date) throws {
        let eventId = "\(eventIdPrefix)\(kind.rawValue)-\(lemmaId)"
        try db.execute(sql: """
            INSERT OR IGNORE INTO nodes (id, kind, created_at) VALUES (?, 'event', ?)
            """, arguments: [eventId, now])
        try db.execute(sql: """
            INSERT OR REPLACE INTO comp_word_event
                (entity_id, lemma_id, region_id, event_kind, trust, occurred_at, detail_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [eventId, lemmaId, regionId, kind.rawValue, trust, occurredAt, detailJson])
        let lemmaEdgeId = "we-lemma-\(eventId)"
        let regionEdgeId = "we-region-\(eventId)"
        for edgeId in [lemmaEdgeId, regionEdgeId] {
            try db.execute(sql: """
                INSERT OR IGNORE INTO nodes (id, kind, created_at) VALUES (?, 'edge', ?)
                """, arguments: [edgeId, now])
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO edges (id, src_id, dst_id, rel_type, created_at)
            VALUES (?, ?, ?, 'produces', ?)
            """, arguments: [lemmaEdgeId, lemmaId, eventId, now])
        try db.execute(sql: """
            INSERT OR IGNORE INTO edges (id, src_id, dst_id, rel_type, created_at)
            VALUES (?, ?, ?, 'contains', ?)
            """, arguments: [regionEdgeId, regionId, eventId, now])
    }
}
