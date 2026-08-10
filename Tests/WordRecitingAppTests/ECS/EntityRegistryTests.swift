import XCTest
import GRDB
@testable import WordRecitingApp

final class EntityRegistryTests: XCTestCase {

    private var appDB: AppDatabase!
    private var registry: EntityRegistry!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        registry = EntityRegistry(database: appDB)
    }

    // MARK: - tableNameMap

    func testTableNameMapCoversAllComponentIDs() throws {
        for id in ComponentID.allCases {
            XCTAssertNotNil(EntityRegistry.tableNameMap[id], "Missing table for \(id)")
        }
        XCTAssertEqual(EntityRegistry.tableNameMap[.text], "comp_text")
        XCTAssertEqual(EntityRegistry.tableNameMap[.lemmaMeta], "comp_lemma_meta")
        XCTAssertEqual(EntityRegistry.tableNameMap[.scheduleState], "comp_schedule_state")
        XCTAssertEqual(EntityRegistry.tableNameMap[.importFailure], "comp_import_failure")
    }

    // MARK: - insertNode / fetchNode

    func testInsertNodeThenFetch() throws {
        // GRDB 存 DATETIME 截断到秒，用整秒 Date 避免 round-trip 精度丢失
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try registry.insertNode(id: "card-1", kind: .card, createdAt: now)
        let row = try registry.fetchNode(id: "card-1")
        XCTAssertEqual(row?.id, "card-1")
        XCTAssertEqual(row?.kind, .card)
        XCTAssertEqual(row?.createdAt, now)
    }

    func testFetchNonexistentNodeReturnsNil() throws {
        let row = try registry.fetchNode(id: "nope")
        XCTAssertNil(row)
    }

    // MARK: - upsertComponent / fetchComponents

    func testUpsertThenFetchTextComponent() throws {
        try registry.insertNode(id: "c1", kind: .card, createdAt: Date())
        try registry.upsertComponent(TextComponent(entityId: "c1", textA: "hello", textB: "你好", language: "en"))
        let fetched: TextComponent? = try registry.fetchComponents(for: "c1", table: "comp_text")
        XCTAssertEqual(fetched?.textA, "hello")
        XCTAssertEqual(fetched?.textB, "你好")
    }

    func testUpsertIsIdempotentUpdate() throws {
        try registry.insertNode(id: "c2", kind: .card, createdAt: Date())
        try registry.upsertComponent(TextComponent(entityId: "c2", textA: "old", textB: nil, language: nil))
        try registry.upsertComponent(TextComponent(entityId: "c2", textA: "new", textB: "x", language: nil))
        let fetched: TextComponent? = try registry.fetchComponents(for: "c2", table: "comp_text")
        XCTAssertEqual(fetched?.textA, "new")
        XCTAssertEqual(fetched?.textB, "x")
        // 只有一行
        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_text WHERE entity_id = ?", arguments: ["c2"])
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - filterEntityIDs (核心)

    func testFilterEntityIDsRequiringAll() throws {
        // 3 个 CardNode，只给 2 个挂 comp_text + comp_schedule_state
        try registry.insertNode(id: "card-a", kind: .card, createdAt: Date())
        try registry.insertNode(id: "card-b", kind: .card, createdAt: Date())
        try registry.insertNode(id: "card-c", kind: .card, createdAt: Date())

        try registry.upsertComponent(TextComponent(entityId: "card-a", textA: "a", textB: nil, language: nil))
        try registry.upsertComponent(ScheduleStateComponent(entityId: "card-a", stability: 1, difficulty: 1, dueAt: nil, intervalDays: 1, reps: 1, lapses: 0, lastRating: 3, lastReviewedAt: nil, schedulerId: "fsrs-v4", queue: "review", customDataJson: nil))

        try registry.upsertComponent(TextComponent(entityId: "card-b", textA: "b", textB: nil, language: nil))
        try registry.upsertComponent(ScheduleStateComponent(entityId: "card-b", stability: 2, difficulty: 2, dueAt: nil, intervalDays: 2, reps: 2, lapses: 0, lastRating: 3, lastReviewedAt: nil, schedulerId: "fsrs-v4", queue: "review", customDataJson: nil))

        // card-c 不挂任何组件

        let ids = try registry.filterEntityIDs(requiringAll: [.text, .scheduleState])
        XCTAssertEqual(Set(ids), Set(["card-a", "card-b"]))
    }

    func testFilterEntityIDsEmptyRequirementReturnsAllNodes() throws {
        try registry.insertNode(id: "n1", kind: .card, createdAt: Date())
        try registry.insertNode(id: "n2", kind: .deck, createdAt: Date())
        let ids = try registry.filterEntityIDs(requiringAll: [])
        XCTAssertEqual(Set(ids), Set(["n1", "n2"]))
    }

    func testFilterEntityIDsNoMatchReturnsEmpty() throws {
        try registry.insertNode(id: "n3", kind: .card, createdAt: Date())
        let ids = try registry.filterEntityIDs(requiringAll: [.text])
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - insertEdge

    func testInsertEdgeCreatesEdgeNodeAndEdgeRow() throws {
        try registry.insertNode(id: "deck-1", kind: .deck, createdAt: Date())
        try registry.insertNode(id: "card-1", kind: .card, createdAt: Date())
        try registry.insertEdge(id: "edge-1", srcId: "deck-1", dstId: "card-1", rel: .has, createdAt: Date())

        // nodes 表有 kind=edge 的行
        let edgeNode = try registry.fetchNode(id: "edge-1")
        XCTAssertEqual(edgeNode?.kind, .edge)

        // edges 表也有行
        let edgeCount = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE id = ?", arguments: ["edge-1"])
        }
        XCTAssertEqual(edgeCount, 1)

        let edgeRow = try appDB.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM edges WHERE id = ?", arguments: ["edge-1"])
        }
        XCTAssertEqual(edgeRow?["src_id"], "deck-1")
        XCTAssertEqual(edgeRow?["dst_id"], "card-1")
        XCTAssertEqual(edgeRow?["rel_type"], "has")
    }

    // MARK: - deleteNode (CASCADE)

    func testDeleteNodeCascadesToComponents() throws {
        try registry.insertNode(id: "card-x", kind: .card, createdAt: Date())
        try registry.upsertComponent(TextComponent(entityId: "card-x", textA: "hi", textB: nil, language: nil))
        try registry.upsertComponent(ScheduleStateComponent(entityId: "card-x", stability: 1, difficulty: 1, dueAt: nil, intervalDays: 1, reps: 1, lapses: 0, lastRating: 3, lastReviewedAt: nil, schedulerId: "fsrs-v4", queue: "review", customDataJson: nil))

        try registry.deleteNode(id: "card-x")

        // node 没了
        XCTAssertNil(try registry.fetchNode(id: "card-x"))
        // comp_text 被 CASCADE 删
        let textCount = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_text WHERE entity_id = ?", arguments: ["card-x"])
        }
        XCTAssertEqual(textCount, 0)
        // comp_schedule_state 被 CASCADE 删
        let schedCount = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_schedule_state WHERE entity_id = ?", arguments: ["card-x"])
        }
        XCTAssertEqual(schedCount, 0)
    }

    func testDeleteNodeCascadesToEdges() throws {
        try registry.insertNode(id: "deck-2", kind: .deck, createdAt: Date())
        try registry.insertNode(id: "card-2", kind: .card, createdAt: Date())
        try registry.insertEdge(id: "edge-2", srcId: "deck-2", dstId: "card-2", rel: .has, createdAt: Date())

        // 删 deck：edge 行（src_id FK）被 CASCADE 删，edge node（edges.id FK）也被 CASCADE 删
        try registry.deleteNode(id: "deck-2")

        let edgeRow = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE id = ?", arguments: ["edge-2"])
        }
        XCTAssertEqual(edgeRow, 0)
        let edgeNode = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nodes WHERE id = ?", arguments: ["edge-2"])
        }
        XCTAssertEqual(edgeNode, 0)
    }
}
