import XCTest
import GRDB
@testable import WordRecitingApp

/// DeckCleanupSystem：删除词库（deck + 卡片），但**保留**全局词汇认知。
/// @ai: 核心约束——「状态与卡片彻底分离」。删词库不等于忘词：
///      重新导入同一词库不应丢掉复习进度，所以 user_known / mastery / 词事件必须留着。
final class DeckCleanupSystemTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
        }
    }

    /// 造一个「1 deck + 2 card + 2 lemma」的最小词库，并给词打上「会」与复习记录。
    private func seedDeck() throws {
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "card-1", kind: .card, createdAt: now),
                .init(id: "card-2", kind: .card, createdAt: now),
                .init(id: "lemma:abandon", kind: .lemma, createdAt: now),
                .init(id: "lemma:battle", kind: .lemma, createdAt: now),
            ],
            textComponents: [
                .init(entityId: "card-1", textA: "abandon", textB: "放弃", language: nil),
                .init(entityId: "card-2", textA: "battle", textB: "战斗", language: nil),
                .init(entityId: "lemma:abandon", textA: "abandon", textB: "放弃", language: "en"),
                .init(entityId: "lemma:battle", textA: "battle", textB: "战斗", language: "en"),
            ],
            deckMetas: [
                .init(entityId: "deck-1", name: "测试词库", sourceKind: "anki",
                      sourcePath: nil, importedAt: now),
            ],
            edges: [
                .init(id: "e-has-1", srcId: "deck-1", dstId: "card-1", rel: .has, createdAt: now),
                .init(id: "e-has-2", srcId: "deck-1", dstId: "card-2", rel: .has, createdAt: now),
                .init(id: "e-inst-1", srcId: "card-1", dstId: "lemma:abandon",
                      rel: .instantiates, createdAt: now),
                .init(id: "e-inst-2", srcId: "card-2", dstId: "lemma:battle",
                      rel: .instantiates, createdAt: now),
            ],
            failures: [])
        try world.run(ImportSystem(), context: batch)

        // 全局词汇认知：标记「会」+ 一条词事件（模拟真实学习状态）
        try world.run(UserKnownSystem(), context: .markKnown(
            lemmaId: "lemma:abandon", source: "manual"))
        RegionRecorder(world: world).record(
            lemmaIds: ["lemma:abandon"],
            region: .study(cardId: "card-1"),
            kind: .quizCorrect)
    }

    // MARK: - 删除

    func testDeleteDeckRemovesDeckAndCards() throws {
        try seedDeck()
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'deck'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'card'"), 2)

        try world.run(DeckCleanupSystem(), context: .delete(deckId: "deck-1"))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'deck'"), 0,
                       "deck 节点应删除")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'card'"), 0,
                       "卡片节点应一并删除")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_deck_meta"), 0,
                       "deck 元数据应随 CASCADE 清理")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_schedule_state"), 0,
                       "卡片调度状态应随 CASCADE 清理")
    }

    /// 卡片相关的边不能变成悬空边（edges 行也是 node）。
    func testDeleteDeckRemovesCardEdges() throws {
        try seedDeck()
        try world.run(DeckCleanupSystem(), context: .delete(deckId: "deck-1"))

        let dangling = try count("""
            SELECT COUNT(*) FROM edges e
            WHERE NOT EXISTS (SELECT 1 FROM nodes n WHERE n.id = e.src_id)
               OR NOT EXISTS (SELECT 1 FROM nodes n WHERE n.id = e.dst_id)
            """)
        XCTAssertEqual(dangling, 0, "不应残留悬空边")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'has'"), 0)
        XCTAssertEqual(
            try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'instantiates'"), 0)
    }

    /// @ai: 最关键的一条——删词库必须**保留**全局词汇认知。
    func testDeleteDeckPreservesGlobalVocabularyState() throws {
        try seedDeck()
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_user_known"), 1)
        let eventsBefore = try count("SELECT COUNT(*) FROM comp_word_event")
        XCTAssertGreaterThan(eventsBefore, 0)

        try world.run(DeckCleanupSystem(), context: .delete(deckId: "deck-1"))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_user_known"), 1,
                       "「会/不会」是全局认知，删词库不应清除")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), eventsBefore,
                       "词事件（学习历史）应保留")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 2,
                       "lemma 保留（变成 orphan，供词汇页继续展示）")
    }

    /// 只删目标 deck，其他词库不受影响。
    func testDeleteDeckLeavesOtherDecksIntact() throws {
        try seedDeck()
        // 第二个词库
        let batch = ImportBatch(
            deckId: "deck-2",
            nodes: [
                .init(id: "deck-2", kind: .deck, createdAt: now),
                .init(id: "card-9", kind: .card, createdAt: now),
            ],
            textComponents: [.init(entityId: "card-9", textA: "zebra", textB: nil, language: nil)],
            deckMetas: [.init(entityId: "deck-2", name: "另一个", sourceKind: "csv",
                              sourcePath: nil, importedAt: now)],
            edges: [
                .init(id: "e-has-9", srcId: "deck-2", dstId: "card-9", rel: .has, createdAt: now),
            ],
            failures: [])
        try world.run(ImportSystem(), context: batch)

        try world.run(DeckCleanupSystem(), context: .delete(deckId: "deck-1"))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'deck'"), 1)
        XCTAssertEqual(
            try count("SELECT COUNT(*) FROM comp_deck_meta WHERE entity_id = 'deck-2'"), 1,
            "另一个词库应完好")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'card'"), 1)
    }

    /// 空 deck（没有卡片）也能删掉，不应因取不到 card 列表而提前 return 掉删除。
    func testDeleteEmptyDeck() throws {
        try appDB.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO nodes (id, kind, created_at) VALUES ('deck-empty', 'deck', ?)",
                arguments: [now])
            try db.execute(sql: """
                INSERT INTO comp_deck_meta (entity_id, name, source_kind, imported_at)
                VALUES ('deck-empty', '空库', 'csv', ?)
                """, arguments: [now])
        }
        try world.run(DeckCleanupSystem(), context: .delete(deckId: "deck-empty"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'deck'"), 0)
    }

    // MARK: - 单张卡片

    func testDeleteSingleCardKeepsOthersAndLemma() throws {
        try seedDeck()
        try world.run(DeckCleanupSystem(), context: .deleteCard(cardId: "card-1"))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'card'"), 1,
                       "只删目标卡片")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'deck'"), 1,
                       "词库保留")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 2,
                       "Lemma 保留（全局词汇档案）")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_user_known"), 1,
                       "掌握度保留")
        // card-1 的两条边（has + instantiates）都要消失，且不留悬空边
        XCTAssertEqual(try count("""
            SELECT COUNT(*) FROM edges
            WHERE src_id = 'card-1' OR dst_id = 'card-1'
            """), 0)
        XCTAssertEqual(try count("""
            SELECT COUNT(*) FROM edges e
            WHERE NOT EXISTS (SELECT 1 FROM nodes n WHERE n.id = e.src_id)
               OR NOT EXISTS (SELECT 1 FROM nodes n WHERE n.id = e.dst_id)
            """), 0, "不应残留悬空边")
    }
}
