import XCTest
import GRDB
@testable import WordRecitingApp

/// db: 版本查询必须能在写事务内使用（System 场景）。
final class GraphQueriesRegionDbTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func record(_ lemmaIds: [EntityID], _ region: RegionRef, _ kind: WordEventKind,
                        trust: Double? = nil) throws {
        try world.run(RegionSystem(), context: .record(
            lemmaIds: lemmaIds, region: region, kind: kind, trust: trust, detail: nil))
    }

    func testDbVersionWorksInsideWriteTransaction() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .lookup)
        try record(["L1"], .dictionary(), .markUnknown, trust: 1.0)

        try appDB.dbWriter.write { db in
            let events = try world.graph.wordEvents(db, lemmaId: "L1", ascending: true)
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(Set(events.map(\.kind)), ["lookup", "mark_unknown"])
            XCTAssertEqual(try world.graph.distinctRegionCount(db, lemmaId: "L1"), 1)
            XCTAssertNil(try world.graph.lemmaFrequency(db, lemmaId: "L1"))
        }
    }

    func testAscendingAndDescendingOrders() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .lookup)

        try appDB.dbWriter.read { db in
            XCTAssertEqual(try world.graph.wordEvents(db, lemmaId: "L1", ascending: true).count, 1)
            XCTAssertEqual(try world.graph.wordEvents(db, lemmaId: "L1", ascending: false).count, 1)
        }
    }

    func testDbVersionReadsFrequency() throws {
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "test"))

        try appDB.dbWriter.write { db in
            let row = try world.graph.lemmaFrequency(db, lemmaId: "L1")
            XCTAssertEqual(row?.band, 2)
            XCTAssertEqual(row?.freqRank, 1001)
        }
    }

    func testConvenienceStillWorks() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .lookup)

        XCTAssertEqual(try world.graph.wordEvents(lemmaId: "L1").count, 1)
        XCTAssertEqual(try world.graph.distinctRegionCount(lemmaId: "L1"), 1)
        XCTAssertNil(try world.graph.lemmaFrequency(lemmaId: "L1"))
    }
}
