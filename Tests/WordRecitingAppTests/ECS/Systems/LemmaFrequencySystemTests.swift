import XCTest
import GRDB
@testable import WordRecitingApp

final class LemmaFrequencySystemTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var provider: BundledWordFrequencyProvider!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        let json = """
        {"source":"test-3k","families":[
          {"rank":1,"band":1,"members":["the"]},
          {"rank":1001,"band":2,"members":["abandon","abandoned"]}
        ]}
        """
        provider = try BundledWordFrequencyProvider(data: Data(json.utf8))
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func frequency(_ lemmaId: String) throws -> LemmaFrequencyComponent? {
        try world.registry.fetchComponents(for: lemmaId, table: "comp_lemma_frequency")
    }

    func testStampSingleLemma() throws {
        try makeLemma("L1", "abandon")
        try world.run(LemmaFrequencySystem(provider: provider), context: .stamp(lemmaId: "L1"))

        XCTAssertEqual(try frequency("L1")?.band, 2)
        XCTAssertEqual(try frequency("L1")?.freqRank, 1001)
        XCTAssertEqual(try frequency("L1")?.source, "test-3k")
    }

    func testStampIsIdempotent() throws {
        try makeLemma("L1", "abandon")
        let system = LemmaFrequencySystem(provider: provider)
        try world.run(system, context: .stamp(lemmaId: "L1"))
        try world.run(system, context: .stamp(lemmaId: "L1"))

        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_lemma_frequency")
        }
        XCTAssertEqual(count, 1)
    }

    func testStampAllOnlyStampsLemmasAndSkipsOffList() throws {
        try makeLemma("L1", "the")
        try makeLemma("L2", "abandon")
        try makeLemma("L3", "zzzzz")
        try world.registry.insertNode(id: "C1", kind: .card, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "C1", textA: "the", textB: nil, language: nil))

        try world.run(LemmaFrequencySystem(provider: provider), context: .stampAll)

        XCTAssertEqual(try frequency("L1")?.band, 1)
        XCTAssertEqual(try frequency("L2")?.band, 2)
        XCTAssertNil(try frequency("L3"))
        XCTAssertNil(try frequency("C1"))
    }
}
