import XCTest
import GRDB
@testable import WordRecitingApp

final class RegionRecorderTests: XCTestCase {
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

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    func testRecordByLemmaIds() throws {
        try makeLemma("L1", "abandon")
        RegionRecorder(world: world).record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .lookup)

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 1)
    }

    func testRecordBySurfacesResolvesLemmaIds() throws {
        try makeLemma("L1", "abandon")
        RegionRecorder(world: world).record(
            surfaces: ["abandon", "zzzzz"], region: .dictionary(), kind: .markUnknown, trust: 1.0)

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE trust = 1"), 1)
    }

    func testEmptyInputIsNoOp() throws {
        RegionRecorder(world: world).record(
            lemmaIds: [], region: .dictionary(), kind: .lookup)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 0)
    }

    /// 记录失败不抛错（事件流是辅助数据）。
    func testFailureIsSwallowed() throws {
        RegionRecorder(world: world).record(
            lemmaIds: ["L404"], region: .dictionary(), kind: .lookup)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 0)
    }

    func testRecordAlsoUpdatesBelief() throws {
        try makeLemma("L1", "abandon")
        RegionRecorder(world: world).record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .markKnown, trust: 1.0)

        let belief: MasteryBeliefComponent? = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief")
        XCTAssertNotNil(belief)
        XCTAssertEqual(belief?.opportunities, 1)
        XCTAssertGreaterThan(belief?.belief ?? 0, BKTParameters.default.fallbackPrior)
    }

    func testRecordBySurfacesAlsoUpdatesBelief() throws {
        try makeLemma("L1", "abandon")
        RegionRecorder(world: world).record(
            surfaces: ["abandon"], region: .rss(articleId: "A1", title: nil),
            kind: .seen, trust: 0)

        let belief: MasteryBeliefComponent? = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief")
        XCTAssertNotNil(belief)
    }
}
