import XCTest
import GRDB
@testable import WordRecitingApp

final class GraphQueriesVocabularyTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
    }

    private func makeLemma(_ id: String, _ text: String, definition: String? = nil) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: now)
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: definition, language: nil))
        if let definition {
            try world.registry.upsertComponent(LemmaDefinitionComponent(
                entityId: id,
                definitionsJson: """
                [{"source":"deck:1","definition":"\(definition)"}]
                """))
        }
    }

    // MARK: - lemmaMastery

    func testLemmaMasteryNilWithoutRecord() throws {
        try makeLemma("L1", "abandon")
        XCTAssertNil(try graph.lemmaMastery(lemmaId: "L1"))
    }

    func testLemmaMasteryReturnsValue() throws {
        try makeLemma("L1", "abandon")
        try world.run(UserKnownSystem(), context: .markUnknown(lemmaId: "L1", source: "init"))
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: "L1"), 1.0)
    }

    // MARK: - knownLemmaMastery

    func testKnownLemmaMasteryReturnsAll() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "battle")
        try makeLemma("L3", "cold")
        try world.run(UserKnownSystem(), context: .batch(
            words: [("abandon", false), ("battle", true)], source: "init"))

        let all = try graph.knownLemmaMastery()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[try XCTUnwrap(graph.findLemmaId(byTextA: "abandon"))], 1.0)
        XCTAssertEqual(all[try XCTUnwrap(graph.findLemmaId(byTextA: "battle"))], 2.0)
    }

    // MARK: - lemmaDefinitions

    func testLemmaDefinitionsParsesEntries() throws {
        try makeLemma("L1", "abandon", definition: "放弃")
        let defs = try graph.lemmaDefinitions(lemmaId: "L1")
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs.first?.source, "deck:1")
        XCTAssertEqual(defs.first?.definition, "放弃")
    }

    func testLemmaDefinitionsEmptyWithoutRecord() throws {
        try makeLemma("L1", "abandon")
        XCTAssertTrue(try graph.lemmaDefinitions(lemmaId: "L1").isEmpty)
    }

    // MARK: - masteryOverview

    func testMasteryOverviewCounts() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "battle")
        try makeLemma("L3", "cold")
        try world.run(UserKnownSystem(), context: .batch(
            words: [("abandon", false), ("battle", true)], source: "init"))

        let overview = try graph.masteryOverview()
        XCTAssertEqual(overview.known, 1)
        XCTAssertEqual(overview.unknown, 1)
        XCTAssertEqual(overview.seen, 0)
        XCTAssertEqual(overview.unmarked, 1)
    }

    // MARK: - 出现过（seen）

    func testAllLemmaSeenCounts() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "battle")
        try world.run(UserKnownSystem(), context: .markSeen(
            words: ["abandon", "battle", "battle"], source: "rss"))

        let seen = try graph.allLemmaSeenCounts()
        XCTAssertEqual(seen[try XCTUnwrap(graph.findLemmaId(byTextA: "abandon"))], 1)
        XCTAssertEqual(seen[try XCTUnwrap(graph.findLemmaId(byTextA: "battle"))], 2)
    }

    func testMasteryOverviewCountsSeen() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "battle")
        // abandon 出现在文章（seen，未判定）；battle 标会
        try world.run(UserKnownSystem(), context: .markSeen(words: ["abandon"], source: "rss"))
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: "L2", source: "init"))

        let overview = try graph.masteryOverview()
        XCTAssertEqual(overview.known, 1)
        XCTAssertEqual(overview.seen, 1)
        XCTAssertEqual(overview.unknown, 0)
        XCTAssertEqual(overview.unmarked, 0)
    }

    // MARK: - 已记录词汇表（词表浏览）

    func testRecordedLemmasReturnsAllStates() throws {
        try makeLemma("L1", "abandon", definition: "放弃")
        try makeLemma("L2", "battle")
        try makeLemma("L3", "cold")
        try makeLemma("L4", "dust")
        // abandon 不会、battle 会、cold 仅 seen、dust 无记录
        try world.run(UserKnownSystem(), context: .batch(
            words: [("abandon", false), ("battle", true)], source: "init"))
        try world.run(UserKnownSystem(), context: .markSeen(words: ["cold"], source: "rss"))

        let all = try graph.recordedLemmas()
        XCTAssertEqual(all.count, 3, "只返回有记录（mastery>0 或 seen>0）的词")

        let abandon = try XCTUnwrap(all.first { $0.text == "abandon" })
        XCTAssertEqual(abandon.mastery, 1.0)
        XCTAssertEqual(abandon.source, "init")
        XCTAssertEqual(abandon.definition, "放弃")
        XCTAssertEqual(abandon.seenCount, 0)

        let battle = try XCTUnwrap(all.first { $0.text == "battle" })
        XCTAssertEqual(battle.mastery, 2.0)

        let cold = try XCTUnwrap(all.first { $0.text == "cold" })
        XCTAssertEqual(cold.mastery, 0.0, "仅 seen 的词 mastery 为 0")
        XCTAssertEqual(cold.seenCount, 1)

        // 统一状态判定：会/不会/出现过
        XCTAssertEqual(WordMarkState.from(mastery: battle.mastery, seenCount: battle.seenCount), .known)
        XCTAssertEqual(WordMarkState.from(mastery: abandon.mastery, seenCount: abandon.seenCount), .unknown)
        XCTAssertEqual(WordMarkState.from(mastery: cold.mastery, seenCount: cold.seenCount), .seen)
    }

    func testRecordedLemmasOrderedByUpdatedDesc() throws {
        try makeLemma("L1", "alpha")
        try makeLemma("L2", "beta")
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: "L1", source: "init"))
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: "L2", source: "init"))
        // L2 后写 → updated_at 更大 → 排前
        let all = try graph.recordedLemmas()
        XCTAssertEqual(all.first?.lemmaID, "L2")
    }
}
