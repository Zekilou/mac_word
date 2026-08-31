import XCTest
import GRDB
@testable import WordRecitingApp

final class LemmaSystemTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
    }

    private func ensure(_ textA: String, source: String = "deck:1",
                        definition: String? = nil) throws -> EntityID {
        try world.run(LemmaSystem(), context: .ensure(LemmaInput(
            textA: textA, textB: definition, source: source,
            definition: definition, createdAt: now)))
        // 用归一化词形反查（变体/音标尾巴词形归并后 lemma 的 text_a 是干净词形）
        return try XCTUnwrap(graph.findLemmaId(byTextA: WordNormalizer.normalize(textA)))
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    // MARK: - 新建

    func testEnsureCreatesLemmaWithTextAndDefinition() throws {
        let id = try ensure("abandon", definition: "放弃")

        XCTAssertEqual(id, "lemma:abandon")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 1)
        let text: TextComponent? = try world.registry.fetchComponents(for: id, table: "comp_text")
        XCTAssertEqual(text?.textA, "abandon")
        XCTAssertEqual(text?.textB, "放弃")
        // 释义写入多来源合并表
        let defs = try graph.lemmaDefinitions(lemmaId: id)
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs.first?.source, "deck:1")
        XCTAssertEqual(defs.first?.definition, "放弃")
    }

    // MARK: - 复用（大小写 / 变体 / 音标尾巴）

    func testEnsureReusesSameLemmaCaseInsensitive() throws {
        let first = try ensure("Abandon")
        let second = try ensure("abandon")
        XCTAssertEqual(first, second)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 1)
    }

    func testEnsureMergesVariantsIntoOneLemma() throws {
        let base = try ensure("battle")
        let variant = try ensure("battles")
        XCTAssertEqual(base, variant)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 1)
    }

    func testEnsureMergesPhoneticTailVariant() throws {
        let clean = try ensure("abandon")
        let tailed = try ensure("abandon[ə'bændən]")
        XCTAssertEqual(clean, tailed)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 1)
    }

    // MARK: - 多来源释义合并（追加不覆盖）

    func testEnsureAppendsDefinitionsFromDifferentSources() throws {
        let id = try ensure("abandon", source: "deck:1", definition: "放弃")
        try world.run(LemmaSystem(), context: .ensure(LemmaInput(
            textA: "abandon", source: "deck:2", definition: "舍弃", createdAt: now)))

        let defs = try graph.lemmaDefinitions(lemmaId: id)
        XCTAssertEqual(defs.count, 2)
        XCTAssertEqual(Set(defs.map(\.source)), ["deck:1", "deck:2"])
        XCTAssertEqual(Set(defs.map(\.definition)), ["放弃", "舍弃"])
    }

    func testEnsureDoesNotDuplicateSameSourceDefinition() throws {
        let id = try ensure("abandon", source: "deck:1", definition: "放弃")
        try world.run(LemmaSystem(), context: .ensure(LemmaInput(
            textA: "abandon", source: "deck:1", definition: "放弃", createdAt: now)))

        let defs = try graph.lemmaDefinitions(lemmaId: id)
        XCTAssertEqual(defs.count, 1)
    }

    // MARK: - 无有效词形

    func testEnsureEmptyWordReturnsNilAndCreatesNothing() throws {
        try world.run(LemmaSystem(), context: .ensure(LemmaInput(
            textA: "[音标]", source: "deck:1", createdAt: now)))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 0)
    }
}
