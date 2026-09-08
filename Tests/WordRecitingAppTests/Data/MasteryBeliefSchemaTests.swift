import XCTest
import GRDB
@testable import WordRecitingApp

/// 阶段二：BKT 后验概率的存储层。
final class MasteryBeliefSchemaTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry { world.registry }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    func testComponentIDRawValueAppended() {
        XCTAssertEqual(ComponentID.masteryBelief.rawValue, "mastery_belief")
        XCTAssertEqual(ComponentID.allCases.last, .masteryBelief)
    }

    func testTableExists() throws {
        try appDB.dbWriter.read { db in
            XCTAssertTrue(try db.tableExists("comp_mastery_belief"))
        }
    }

    func testIndexExists() throws {
        try appDB.dbWriter.read { db in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
            XCTAssertTrue(names.contains("idx_mastery_belief_belief"))
        }
    }

    func testTableNameMapRegistersNewComponent() {
        XCTAssertEqual(EntityRegistry.tableNameMap[.masteryBelief], "comp_mastery_belief")
    }

    func testComponentRoundTrip() throws {
        let now = Date()
        try registry.insertNode(id: "L1", kind: .lemma, createdAt: now)
        try registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.73, opportunities: 4,
            lastEventAt: now, updatedAt: now, paramsVersion: "bkt-1"))

        let back: MasteryBeliefComponent? = try registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief")
        XCTAssertEqual(back?.belief ?? 0, 0.73, accuracy: 0.0001)
        XCTAssertEqual(back?.opportunities, 4)
        XCTAssertEqual(back?.paramsVersion, "bkt-1")
    }

    func testCascadeOnNodeDelete() throws {
        try appDB.dbWriter.write { db in
            try registry.insertNode(db, id: "L1", kind: .lemma, createdAt: Date())
            try registry.upsertComponent(db, MasteryBeliefComponent(
                entityId: "L1", belief: 0.5, opportunities: 1,
                lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        }
        try appDB.dbWriter.write { db in try registry.deleteNode(db, id: "L1") }
        try appDB.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_mastery_belief"), 0)
        }
    }

    func testMigrationIdempotent() throws {
        XCTAssertNoThrow(try appDB.runMigrations())
        XCTAssertNoThrow(try appDB.runMigrations())
    }
}
