import XCTest
import GRDB
@testable import WordRecitingApp

final class UserKnownSystemTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: now)
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    // MARK: - 单词标记

    func testMarkKnownAndUnknown() throws {
        try makeLemma("L1", "abandon")
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: "L1", source: "init"))
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: "L1"), 2.0)

        try world.run(UserKnownSystem(), context: .markUnknown(lemmaId: "L1", source: "init"))
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: "L1"), 1.0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_user_known"), 1)
    }

    func testAdjustClampsMastery() throws {
        try makeLemma("L1", "abandon")
        // 无记录视为从"不会"(1) 起步
        try world.run(UserKnownSystem(), context: .adjust(lemmaId: "L1", delta: 0.8, source: "article"))
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: "L1") ?? 0, 1.8, accuracy: 0.001)

        // 微调回落
        try world.run(UserKnownSystem(), context: .adjust(lemmaId: "L1", delta: -0.5, source: "article"))
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: "L1") ?? 0, 1.3, accuracy: 0.001)

        // 上 / 下界钳制到 1...2
        try world.run(UserKnownSystem(), context: .adjust(lemmaId: "L1", delta: 5, source: "article"))
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: "L1") ?? 0, 2.0, accuracy: 0.001)
        try world.run(UserKnownSystem(), context: .adjust(lemmaId: "L1", delta: -5, source: "article"))
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: "L1") ?? 0, 1.0, accuracy: 0.001)
    }

    func testMarkKnownForMissingLemmaThrows() {
        XCTAssertThrowsError(try world.run(
            UserKnownSystem(), context: .markKnown(lemmaId: "L99", source: "init"))) { err in
            XCTAssertEqual(err as? UserKnownError, .lemmaNotFound("L99"))
        }
    }

    // MARK: - 批量标记（词元不存在自动创建 Lemma）

    func testBatchCreatesLemmasAndMarks() throws {
        try world.run(UserKnownSystem(), context: .batch(
            words: [("abandon", false), ("battle", true), ("Battles", true)],
            source: "init"))

        // 3 个词 → abandon + battle 两个 Lemma（Battles 归并到 battle）；
        // comp_user_known 按 entity 唯一 → 也是 2 条（Battles 覆盖到 battle 上）
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 2)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_user_known"), 2)

        let abandon = try XCTUnwrap(graph.findLemmaId(byTextA: "abandon"))
        let battle = try XCTUnwrap(graph.findLemmaId(byTextA: "battle"))
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: abandon), 1.0)
        XCTAssertEqual(try graph.lemmaMastery(lemmaId: battle), 2.0)
    }

    // MARK: - 出现过（markSeen）：mastery 不变、seen +1

    func testMarkSeenKeepsMasteryAndIncrements() throws {
        try makeLemma("L1", "abandon")
        // 先标会（mastery=2）
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: "L1", source: "init"))
        // 文章出现：abandon（已有）+ battle（自动建 Lemma）
        try world.run(UserKnownSystem(), context: .markSeen(
            words: ["abandon", "battle"], source: "rss"))

        // abandon：mastery 保持 2（不因出现改变），seen = 1
        let c1: UserKnownComponent? = try world.registry.fetchComponents(
            for: "L1", table: "comp_user_known")
        XCTAssertEqual(c1?.mastery, 2.0)
        XCTAssertEqual(c1?.seenCount, 1)

        // battle：自动建 Lemma，mastery = 0（无记录），seen = 1
        let battle = try XCTUnwrap(graph.findLemmaId(byTextA: "battle"))
        let c2: UserKnownComponent? = try world.registry.fetchComponents(
            for: battle, table: "comp_user_known")
        XCTAssertEqual(c2?.mastery, 0.0)
        XCTAssertEqual(c2?.seenCount, 1)

        // 再次出现 → seen 2，mastery 仍 2
        try world.run(UserKnownSystem(), context: .markSeen(words: ["abandon"], source: "rss"))
        let c3: UserKnownComponent? = try world.registry.fetchComponents(
            for: "L1", table: "comp_user_known")
        XCTAssertEqual(c3?.seenCount, 2)
        XCTAssertEqual(c3?.mastery, 2.0)
    }

    // MARK: - 全局上下文与卡片彻底分离

    func testKnownStateDoesNotCreateCards() throws {
        try world.run(UserKnownSystem(), context: .batch(
            words: [("abandon", false)], source: "init"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'card'"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_schedule_state"), 0)
    }
}
