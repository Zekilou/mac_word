import XCTest
import GRDB
@testable import WordRecitingApp

final class ImportSystemTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    // 构造含 2 DeckNode + 10 CardNode + 1 failure 的 ImportBatch
    private func makeBatch() -> ImportBatch {
        let deckIds = ["deck-1", "deck-2"]
        let cardIds = (0..<10).map { "card-\($0)" }

        var nodes: [ImportBatch.NodeSpec] = []
        for did in deckIds {
            nodes.append(.init(id: did, kind: .deck, createdAt: now))
        }
        for cid in cardIds {
            nodes.append(.init(id: cid, kind: .card, createdAt: now))
        }

        let deckMetas = deckIds.map {
            DeckMetaComponent(entityId: $0, name: $0, sourceKind: "csv",
                              sourcePath: nil, importedAt: now)
        }
        let textComps = cardIds.map {
            TextComponent(entityId: $0, textA: "word-\($0)", textB: nil, language: nil)
        }

        var edges: [ImportBatch.EdgeSpec] = []
        for (i, cid) in cardIds.enumerated() {
            let did = i < 5 ? "deck-1" : "deck-2"
            edges.append(.init(id: "has-\(cid)", srcId: did, dstId: cid,
                               rel: .has, createdAt: now))
        }

        let failures = [ImportBatch.FailureSpec(
            entityId: "fail-1", deckId: "deck-1", rowIndex: 99,
            rawLine: "bad,line", reason: "missing field")]

        return ImportBatch(
            deckId: "deck-1", nodes: nodes, textComponents: textComps,
            deckMetas: deckMetas, scheduleStates: [], edges: edges, failures: failures
        )
    }

    func testImportBatchPersistsAllInOneTransaction() throws {
        let batch = makeBatch()
        try world.run(ImportSystem(), context: batch)

        // 业务节点（deck + card + event），不含 edge 节点：2 + 10 + 1 = 13
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind != 'edge'"), 13)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_deck_meta"), 2)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_text"), 10)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'has'"), 10)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_import_failure"), 1)
        // failure 的 owns 边
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'owns'"), 1)
    }

    func testImportFailureContent() throws {
        let batch = makeBatch()
        try world.run(ImportSystem(), context: batch)

        let fail: ImportFailureComponent? = try world.registry.fetchComponents(
            for: "fail-1", table: "comp_import_failure")
        XCTAssertEqual(fail?.deckId, "deck-1")
        XCTAssertEqual(fail?.rowIndex, 99)
        XCTAssertEqual(fail?.rawLine, "bad,line")
        XCTAssertEqual(fail?.reason, "missing field")
    }

    func testDeckMetaContent() throws {
        let batch = makeBatch()
        try world.run(ImportSystem(), context: batch)

        let meta: DeckMetaComponent? = try world.registry.fetchComponents(
            for: "deck-2", table: "comp_deck_meta")
        XCTAssertEqual(meta?.name, "deck-2")
        XCTAssertEqual(meta?.sourceKind, "csv")
    }

    func testHasEdgesLinkCorrectDecks() throws {
        let batch = makeBatch()
        try world.run(ImportSystem(), context: batch)

        // deck-1 拥有 card-0..4（5 条 has 边），deck-2 拥有 card-5..9（5 条）
        let d1 = try count(
            "SELECT COUNT(*) FROM edges WHERE src_id = ? AND rel_type = 'has'",
            ["deck-1"])
        let d2 = try count(
            "SELECT COUNT(*) FROM edges WHERE src_id = ? AND rel_type = 'has'",
            ["deck-2"])
        XCTAssertEqual(d1, 5)
        XCTAssertEqual(d2, 5)
    }

    // MARK: - 事务原子性

    func testImportRollsBackOnDuplicateNodeId() throws {
        // 先手动插入一个冲突的 node
        try world.registry.insertNode(id: "deck-1", kind: .deck, createdAt: now)

        let batch = makeBatch()
        // ImportSystem 插 deck-1 时 PK 冲突 → 抛错 → 整个事务回滚
        XCTAssertThrowsError(try world.run(ImportSystem(), context: batch))

        // 回滚后：batch 里的 card-0 不应存在
        XCTAssertNil(try world.registry.fetchNode(id: "card-0"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_text"), 0)
    }

    // MARK: - 空壳 System 可被 World.run 调用

    func testShellSystemsAreCallable() throws {
        // 三个空壳 System 应可被 World.run 调用且不抛错（无匹配 entity 也能跑）
        try world.run(StudySystem(), context: ())
        try world.run(ContentGenSystem(), context: ())
        try world.run(AnalyticsSystem(), context: ())
    }
}
