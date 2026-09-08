import XCTest
import GRDB
@testable import WordRecitingApp

/// 阶段一：v4 迁移建表 / 索引 / 级联。
final class RegionSchemaTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry { world.registry }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    func testV4TablesExist() throws {
        try appDB.dbWriter.read { db in
            for table in ["comp_region", "comp_word_event", "comp_lemma_frequency"] {
                XCTAssertTrue(try db.tableExists(table), "缺表：\(table)")
            }
        }
    }

    func testV4IndexesExist() throws {
        try appDB.dbWriter.read { db in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
            XCTAssertTrue(names.contains("idx_word_event_lemma_time"))
            XCTAssertTrue(names.contains("idx_word_event_region"))
            XCTAssertTrue(names.contains("idx_region_source"))
        }
    }

    func testV4Idempotent() throws {
        XCTAssertNoThrow(try appDB.runMigrations())
        XCTAssertNoThrow(try appDB.runMigrations())
    }

    func testWordEventCascadeOnNodeDelete() throws {
        let now = Date()
        try appDB.dbWriter.write { db in
            try registry.insertNode(db, id: "L1", kind: .lemma, createdAt: now)
            try registry.insertNode(db, id: "R1", kind: .region, createdAt: now)
            try registry.insertNode(db, id: "E1", kind: .event, createdAt: now)
            try registry.upsertComponent(db, WordEventComponent(
                entityId: "E1", lemmaId: "L1", regionId: "R1",
                eventKind: WordEventKind.seen.rawValue, trust: 0,
                occurredAt: now, detailJson: nil))
        }
        try appDB.dbWriter.write { db in try registry.deleteNode(db, id: "E1") }
        try appDB.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_word_event"), 0)
        }
    }
}
