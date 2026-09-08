import XCTest
@testable import WordRecitingApp

final class VocabularyMaintenanceTests: XCTestCase {
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

    private func provider() throws -> BundledWordFrequencyProvider {
        try BundledWordFrequencyProvider(data: Data("""
        {"source":"test","families":[
          {"rank":1,"band":1,"members":["the"]},
          {"rank":1001,"band":2,"members":["abandon"]}
        ]}
        """.utf8))
    }

    func testBackfillStampsExistingLemmas() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "the")
        VocabularyMaintenance.backfillLemmaFrequency(world: world, provider: try provider())

        XCTAssertEqual(try world.graph.lemmaFrequency(lemmaId: "L1")?.band, 2)
        XCTAssertEqual(try world.graph.lemmaFrequency(lemmaId: "L2")?.band, 1)
    }

    func testBackfillIsIdempotent() throws {
        try makeLemma("L1", "abandon")
        let p = try provider()
        VocabularyMaintenance.backfillLemmaFrequency(world: world, provider: p)
        VocabularyMaintenance.backfillLemmaFrequency(world: world, provider: p)

        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_lemma_frequency")
        }
        XCTAssertEqual(count, 1)
    }

    func testBackfillWithoutProviderIsNoOp() throws {
        try makeLemma("L1", "abandon")
        VocabularyMaintenance.backfillLemmaFrequency(world: world, provider: nil)

        XCTAssertEqual(try world.graph.allLemmaFrequencies().count, 0)
    }

    func testBackfillMasteryRecomputesAll() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .markKnown,
            trust: 1.0, detail: nil))

        VocabularyMaintenance.backfillMastery(world: world)

        let belief: MasteryBeliefComponent? = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief")
        XCTAssertNotNil(belief)
        XCTAssertEqual(belief?.opportunities, 1)
    }

    func testBackfillMasteryIsIdempotent() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .markKnown,
            trust: 1.0, detail: nil))

        VocabularyMaintenance.backfillMastery(world: world)
        let first = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief") as MasteryBeliefComponent?
        VocabularyMaintenance.backfillMastery(world: world)
        let second = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief") as MasteryBeliefComponent?

        XCTAssertEqual(first?.belief ?? 0, second?.belief ?? -1, accuracy: 0.0001)
        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_mastery_belief")
        }
        XCTAssertEqual(count, 1)
    }
}
