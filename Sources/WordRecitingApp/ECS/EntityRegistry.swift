import GRDB
import Foundation

/// ECS 核心读写层：持有 AppDatabase，提供 nodes/edges/comp_* 的 CRUD
/// 以及按组件签名（INNER JOIN）过滤 entity_id 的核心查询。
/// 每个方法都有两个版本：
///  - db 版本（接收 Database）：在 World.run 的事务内复用，不自己开事务；
///  - 便捷版本（无 db）：自己开读/写事务，适合非 System 场景（如测试、一次性操作）。
/// @ai: System 内必须用 db 版本，确保写入在同一事务内。
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
        .userKnown: "comp_user_known",
        .lemmaDefinition: "comp_lemma_definitions",
    ]

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Node（db 版本）

    /// 向 nodes 表插入一行（在传入事务内）。
    func insertNode(_ db: Database, id: EntityID, kind: NodeKind, createdAt: Date) throws {
        try db.execute(
            sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)",
            arguments: [id, kind.rawValue, createdAt]
        )
    }

    /// 从 nodes 表查一行（在传入事务内）。
    func fetchNode(_ db: Database, id: EntityID) throws -> NodeRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, kind, created_at FROM nodes WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        guard let kindRaw: String = row["kind"],
              let kind = NodeKind(rawValue: kindRaw)
        else { return nil }
        return NodeRow(id: row["id"], kind: kind, createdAt: row["created_at"])
    }

    /// 从 nodes 表删除（CASCADE 自动删组件与 edges）（在传入事务内）。
    func deleteNode(_ db: Database, id: EntityID) throws {
        try db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [id])
    }

    // MARK: - Edge（db 版本）

    /// 向 edges 表插入一行，同时插入 kind=edge 的 node（edges.id FK → nodes.id）。
    func insertEdge(
        _ db: Database, id: EntityID, srcId: EntityID, dstId: EntityID,
        rel: EdgeRel, createdAt: Date
    ) throws {
        try db.execute(
            sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)",
            arguments: [id, NodeKind.edge.rawValue, createdAt]
        )
        try db.execute(
            sql: "INSERT INTO edges (id, src_id, dst_id, rel_type, created_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [id, srcId, dstId, rel.rawValue, createdAt]
        )
    }

    // MARK: - Component（db 版本）

    /// upsert 一个组件到对应表（按 entity_id PK，save = update or insert）。
    func upsertComponent<T: PersistableRecord>(_ db: Database, _ component: T) throws {
        try component.save(db)
    }

    /// 从指定 comp_* 表按 entity_id 查一行。
    func fetchComponents<T: FetchableRecord>(
        _ db: Database, for entityId: EntityID, table: String
    ) throws -> T? {
        try T.fetchOne(
            db,
            sql: "SELECT * FROM \(table) WHERE entity_id = ?",
            arguments: [entityId]
        )
    }

    // MARK: - Component signature filter（db 版本，核心）

    /// 按组件签名 JOIN 过滤：返回同时在所有指定 comp_* 表中有行的 entity_id 集合。
    func filterEntityIDs(
        _ db: Database, requiringAll componentIDs: [ComponentID]
    ) throws -> [EntityID] {
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

    // MARK: - 便捷版本（自开事务，供非 System 场景使用）

    func insertNode(id: EntityID, kind: NodeKind, createdAt: Date) throws {
        try database.dbWriter.write { db in
            try insertNode(db, id: id, kind: kind, createdAt: createdAt)
        }
    }

    func fetchNode(id: EntityID) throws -> NodeRow? {
        try database.dbWriter.read { db in try fetchNode(db, id: id) }
    }

    func deleteNode(id: EntityID) throws {
        try database.dbWriter.write { db in try deleteNode(db, id: id) }
    }

    func insertEdge(
        id: EntityID, srcId: EntityID, dstId: EntityID, rel: EdgeRel, createdAt: Date
    ) throws {
        try database.dbWriter.write { db in
            try insertEdge(db, id: id, srcId: srcId, dstId: dstId, rel: rel, createdAt: createdAt)
        }
    }

    func upsertComponent<T: PersistableRecord>(_ component: T) throws {
        try database.dbWriter.write { db in try upsertComponent(db, component) }
    }

    func fetchComponents<T: FetchableRecord>(
        for entityId: EntityID, table: String
    ) throws -> T? {
        try database.dbWriter.read { db in
            try fetchComponents(db, for: entityId, table: table)
        }
    }

    func filterEntityIDs(requiringAll componentIDs: [ComponentID]) throws -> [EntityID] {
        try database.dbWriter.read { db in
            try filterEntityIDs(db, requiringAll: componentIDs)
        }
    }

    // MARK: - Edge 删除（按 src/dst/rel 找 edge 再删 node，CASCADE 清理组件）

    /// 在事务内按 src/dst/rel 精确查找 edge id，找到则删对应 node（CASCADE 自动删 edges 行 + 组件）。
    /// 返回被删除的 edge id，未找到返回 nil。
    func deleteEdgeIfPresent(
        _ db: Database, srcId: EntityID, dstId: EntityID, rel: EdgeRel
    ) throws -> EntityID? {
        let sql = """
        SELECT e.id FROM edges e
        WHERE e.src_id = ? AND e.dst_id = ? AND e.rel_type = ?
        LIMIT 1
        """
        guard let edgeId: EntityID = try String.fetchOne(
            db, sql: sql, arguments: [srcId, dstId, rel.rawValue])
        else { return nil }
        try deleteNode(db, id: edgeId)
        return edgeId
    }
}

/// nodes 表的一行（id, kind, createdAt）。
struct NodeRow: Sendable, Equatable {
    let id: EntityID
    let kind: NodeKind
    let createdAt: Date
}
