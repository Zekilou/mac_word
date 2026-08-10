import GRDB
import Foundation

/// ECS 核心读写层：持有 AppDatabase，提供 nodes/edges/comp_* 的 CRUD
/// 以及按组件签名（INNER JOIN）过滤 entity_id 的核心查询。
/// 所有写方法各自开启写事务；读方法各自开启读事务。
/// @ai: Task 7 会在 World.run 的事务内复用这些能力（db 参数版本）。
final class EntityRegistry: @unchecked Sendable {
    let database: AppDatabase

    /// ComponentID → comp_* 表名。新增 Component case 时同步追加。
    static let tableNameMap: [ComponentID: String] = [
        .text: "comp_text",
        .lemmaMeta: "comp_lemma_meta",
        .deckMeta: "comp_deck_meta",
        .scheduleState: "comp_schedule_state",
        .reviewEvent: "comp_review_event",
        .mediaRefs: "comp_media_refs",
        .generationMeta: "comp_generation_meta",
        .edgeSpan: "comp_edge_span",
        .edgeWeighted: "comp_edge_weighted",
        .edgePosition: "comp_edge_position",
        .tagSet: "comp_tag_set",
        .order: "comp_order",
        .customData: "comp_custom_data",
        .importFailure: "comp_import_failure",
        .analyticsCache: "comp_analytics_cache",
    ]

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Node

    /// 向 nodes 表插入一行。
    func insertNode(id: EntityID, kind: NodeKind, createdAt: Date) throws {
        try database.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)",
                arguments: [id, kind.rawValue, createdAt]
            )
        }
    }

    /// 从 nodes 表查一行。
    func fetchNode(id: EntityID) throws -> NodeRow? {
        try database.dbWriter.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, kind, created_at FROM nodes WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            guard let kindRaw: String = row["kind"],
                  let kind = NodeKind(rawValue: kindRaw)
            else { return nil }
            return NodeRow(
                id: row["id"],
                kind: kind,
                createdAt: row["created_at"]
            )
        }
    }

    /// 从 nodes 表删除（CASCADE 自动删组件与 edges）。
    func deleteNode(id: EntityID) throws {
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Edge

    /// 向 edges 表插入一行。同时插入 kind=edge 的 node（edges.id FK → nodes.id）。
    func insertEdge(
        id: EntityID, srcId: EntityID, dstId: EntityID, rel: EdgeRel, createdAt: Date
    ) throws {
        try database.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)",
                arguments: [id, NodeKind.edge.rawValue, createdAt]
            )
            try db.execute(
                sql: "INSERT INTO edges (id, src_id, dst_id, rel_type, created_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, srcId, dstId, rel.rawValue, createdAt]
            )
        }
    }

    // MARK: - Component

    /// upsert 一个组件到对应表（按 entity_id PK，save = update or insert）。
    func upsertComponent<T: PersistableRecord>(_ component: T) throws {
        try database.dbWriter.write { db in
            try component.save(db)
        }
    }

    /// 从指定 comp_* 表按 entity_id 查一行。
    func fetchComponents<T: FetchableRecord>(
        for entityId: EntityID, table: String
    ) throws -> T? {
        try database.dbWriter.read { db in
            try T.fetchOne(
                db,
                sql: "SELECT * FROM \(table) WHERE entity_id = ?",
                arguments: [entityId]
            )
        }
    }

    // MARK: - Component signature filter (核心)

    /// 按组件签名 JOIN 过滤：返回同时在所有指定 comp_* 表中有行的 entity_id 集合。
    /// 例如 requiringAll=[.text, .schedule_state] 返回同时挂了这两张表的 entity_id。
    /// 实现方式：用 INNER JOIN 拼接 SQL。
    func filterEntityIDs(requiringAll componentIDs: [ComponentID]) throws -> [EntityID] {
        try database.dbWriter.read { db in
            // 无约束：返回全部 node id
            if componentIDs.isEmpty {
                return try String.fetchAll(db, sql: "SELECT id FROM nodes")
            }
            var sql = "SELECT n.id FROM nodes n"
            for (i, cid) in componentIDs.enumerated() {
                guard let table = Self.tableNameMap[cid] else { continue }
                let alias = "t\(i)"
                sql += " INNER JOIN \(table) \(alias) ON \(alias).entity_id = n.id"
            }
            return try String.fetchAll(db, sql: sql)
        }
    }
}

/// nodes 表的一行（id, kind, createdAt）。
struct NodeRow: Sendable, Equatable {
    let id: EntityID
    let kind: NodeKind
    let createdAt: Date
}
