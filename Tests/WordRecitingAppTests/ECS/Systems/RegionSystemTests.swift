import XCTest
import GRDB
@testable import WordRecitingApp

final class RegionSystemTests: XCTestCase {
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

    // MARK: - region

    func testEnsureIsIdempotent() throws {
        let ref = RegionRef.dictionary()
        try world.run(RegionSystem(), context: .ensure(ref))
        try world.run(RegionSystem(), context: .ensure(ref))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'region'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_region"), 1)
        XCTAssertEqual(try count("SELECT trust FROM comp_region WHERE entity_id = ?", [ref.id]), 1)
    }

    func testRegionRefFactories() {
        XCTAssertEqual(RegionRef.study(cardId: "C1").trust, 1.0)
        XCTAssertEqual(RegionRef.dictionary().trust, 1.0)
        XCTAssertEqual(RegionRef.initSession(sessionId: "S1").trust, 1.0)
        XCTAssertEqual(RegionRef.rss(articleId: "A1", title: "t").trust, 0.0)
        XCTAssertEqual(RegionRef.generate(articleId: "A1", title: nil).trust, 0.0)
    }

    // MARK: - 事件

    func testRecordCreatesEventAndEdges() throws {
        try makeLemma("L1", "abandon")
        let ref = RegionRef.study(cardId: "C1")

        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: ref, kind: .quizWrong, trust: nil, detail: nil))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE lemma_id = ? AND region_id = ? AND event_kind = 'quiz_wrong'",
            ["L1", ref.id]), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM edges WHERE src_id = ? AND rel_type = 'produces'", ["L1"]), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM edges WHERE src_id = ? AND rel_type = 'contains'", [ref.id]), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'event'"), 1)
    }

    func testEventTrustInheritsRegionWhenNoOverride() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .rss(articleId: "A1", title: nil),
            kind: .seen, trust: nil, detail: nil))

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE trust = 0"), 1)
    }

    func testEventTrustOverrideForActiveInteractionInPassiveRegion() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .rss(articleId: "A1", title: nil),
            kind: .markUnknown, trust: 1.0, detail: nil))

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE trust = 1"), 1)
    }

    func testRecordManyAndSkipUnknownLemma() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "ability")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1", "L2", "L404"], region: .dictionary(),
            kind: .lookup, trust: nil, detail: nil))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 2)
    }

    func testRecordKeepsDetailJson() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .generate(articleId: "A1", title: nil),
            kind: .seen, trust: nil, detail: #"{"surface":"abandoned"}"#))

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE detail_json = ?",
            [#"{"surface":"abandoned"}"#]), 1)
    }
}
