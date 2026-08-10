import XCTest
import GRDB
@testable import WordRecitingApp

final class MigrationsTests: XCTestCase {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    // 所有 17 张表必须存在
    func testAllTablesExist() throws {
        let appDB = try makeDB()
        let expectedTables: Set<String> = [
            "nodes", "edges",
            "comp_text", "comp_lemma_meta", "comp_deck_meta",
            "comp_schedule_state", "comp_review_event", "comp_media_refs",
            "comp_generation_meta", "comp_edge_span", "comp_edge_weighted",
            "comp_edge_position", "comp_tag_set", "comp_order",
            "comp_custom_data", "comp_import_failure", "comp_analytics_cache",
        ]
        let actualTables = try appDB.dbWriter.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        for table in expectedTables {
            XCTAssertTrue(actualTables.contains(table), "Missing table: \(table)")
        }
    }

    // 索引存在
    func testIndexesExist() throws {
        let appDB = try makeDB()
        let expectedIndexes: Set<String> = [
            "idx_nodes_kind", "idx_edges_src_rel", "idx_edges_dst_rel",
            "idx_schedule_due", "idx_review_target_time",
            "idx_gen_mode", "idx_cache_lookup",
        ]
        let actualIndexes = try appDB.dbWriter.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'"))
        }
        for idx in expectedIndexes {
            XCTAssertTrue(actualIndexes.contains(idx), "Missing index: \(idx)")
        }
    }

    // comp_text CASCADE: 删 node → comp_text 自动删
    func testCascadeCompText() throws {
        let appDB = try makeDB()
        try appDB.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)",
                           arguments: ["n1", "card", Date()])
            try db.execute(sql: "INSERT INTO comp_text (entity_id, text_a, text_b) VALUES (?, ?, ?)",
                           arguments: ["n1", "front", "back"])
            // 删 node
            try db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: ["n1"])
            // comp_text 应该也被删
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_text WHERE entity_id = ?", arguments: ["n1"])
            XCTAssertEqual(count, 0)
        }
    }

    // edges CASCADE: 删 src node → edge 行 + edge node 自动删
    func testCascadeEdges() throws {
        let appDB = try makeDB()
        try appDB.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)", arguments: ["src", "deck", Date()])
            try db.execute(sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)", arguments: ["dst", "card", Date()])
            try db.execute(sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)", arguments: ["e1", "edge", Date()])
            try db.execute(sql: "INSERT INTO edges (id, src_id, dst_id, rel_type, created_at) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["e1", "src", "dst", "has", Date()])
            // 删 src node
            try db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: ["src"])
            // edge 行应该被删（src_id FK CASCADE）
            let edgeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE id = ?", arguments: ["e1"])
            XCTAssertEqual(edgeCount, 0)
            // edge node 也应该被删（edges.id FK → nodes.id CASCADE）
            let nodeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nodes WHERE id = ?", arguments: ["e1"])
            XCTAssertEqual(nodeCount, 0)
        }
    }

    // 迁移幂等：跑两次不报错
    func testMigrationIdempotent() throws {
        let appDB = try AppDatabase.inMemory()
        // 再跑一次迁移（不应该报错，因为 GRDB migrator 会跳过已执行的迁移）
        try appDB.runMigrations()
    }

    // 所有 comp_* 表的 entity_id 是 PK + FK
    func testCompTablesHaveEntityIdPK() throws {
        let appDB = try makeDB()
        let compTables = [
            "comp_text", "comp_lemma_meta", "comp_deck_meta",
            "comp_schedule_state", "comp_review_event", "comp_media_refs",
            "comp_generation_meta", "comp_edge_span", "comp_edge_weighted",
            "comp_edge_position", "comp_tag_set", "comp_order",
            "comp_custom_data", "comp_import_failure", "comp_analytics_cache",
        ]
        for table in compTables {
            let pk = try appDB.dbWriter.read { db in
                try String.fetchOne(db, sql: "SELECT name FROM pragma_table_info(?) WHERE pk = 1", arguments: [table])
            }
            XCTAssertEqual(pk, "entity_id", "\(table) should have entity_id as PK")
        }
    }
}
