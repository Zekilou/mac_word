import XCTest
import GRDB
@testable import WordRecitingApp

final class ImportSystemTests: XCTestCase {

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

    // MARK: - 幂等 / 事务原子性

    /// 回归：重复导入（或批内重复行）不得因 UNIQUE 冲突整体失败。
    /// @ai: 节点 id 是确定式的（CSV: lemma-<deck>-<词> / card-<deck>-<正面>），
    ///      旧实现在已存在时直接抛错并回滚**整个**导入，
    ///      用户看到「导入失败」且一条都没进（重复导入同一文件、或文件里有同形行都会中招）。
    func testReimportSameBatchIsIdempotent() throws {
        let batch = makeBatch()
        try world.run(ImportSystem(), context: batch)
        let nodesAfterFirst = try count("SELECT COUNT(*) FROM nodes")
        let textsAfterFirst = try count("SELECT COUNT(*) FROM comp_text")

        // 第二次导入同一 batch：不抛错、不重复建节点
        XCTAssertNoThrow(try world.run(ImportSystem(), context: batch))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes"), nodesAfterFirst)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_text"), textsAfterFirst)
    }

    /// 回归：重复导入**不得重置**已复习卡片的调度进度。
    /// @ai: 若复用已有卡片时仍 upsert 初始 schedule_state，
    ///      用户的 reps / due_at / factor 会被打回「新卡」——等于重复导入即清空学习记录。
    func testReimportDoesNotResetScheduleProgress() throws {
        // 用带 scheduleStates 的 batch（makeBatch 不含调度状态，无从验证重置）
        let batch = makeLemmaBatch(deckId: "deck-R", words: [("run", "跑")])
        try world.run(ImportSystem(), context: batch)
        XCTAssertGreaterThan(try count("SELECT COUNT(*) FROM comp_schedule_state"), 0,
                             "前提：本 batch 应写入初始调度状态")

        // 模拟用户已复习到第 7 次、间隔 30 天
        let reviewed = Date(timeIntervalSince1970: 1_800_000_000)
        let future = reviewed.addingTimeInterval(30 * 86400)
        try appDB.dbWriter.write { db in
            try db.execute(sql: """
                UPDATE comp_schedule_state
                SET reps = 7, interval_days = 30, difficulty = 2.5,
                    due_at = ?, last_reviewed_at = ?
                """, arguments: [future, reviewed])
        }

        try world.run(ImportSystem(), context: batch)

        let rows = try appDB.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT reps, interval_days, due_at FROM comp_schedule_state
                """)
        }
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertEqual(row["reps"] as Int?, 7, "重复导入不得把 reps 打回 0")
            let interval: Double? = row["interval_days"]
            XCTAssertEqual(interval ?? -1, 30, accuracy: 0.0001)
            XCTAssertNotNil(row["due_at"] as Date?, "due_at 不得被重置为导入时刻")
        }
    }

    /// 事务原子性：System 抛错时整批回滚（保持既有语义）。
    func testImportRollsBackWhenSystemThrows() throws {
        // 用一个必抛错的 System 验证 World.run 的回滚语义未被幂等改动破坏
        struct ThrowingSystem: System {
            static let requiresAll: [ComponentID] = []
            typealias Context = Void
            func execute(world: World, db: Database, entities: [EntityID], context: Void) throws {
                try world.registry.insertNodeIfAbsent(
                    db, id: "should-be-rolled-back", kind: .card, createdAt: Date())
                throw ImportTestError.boom
            }
        }
        XCTAssertThrowsError(try world.run(ThrowingSystem(), context: ()))
        XCTAssertNil(try world.registry.fetchNode(id: "should-be-rolled-back"),
                     "抛错后必须整事务回滚")
    }

    // MARK: - 空壳 System 可被 World.run 调用

    func testShellSystemsAreCallable() throws {
        // ContentGenSystem 已实现，用空文章验证可调用；
        // AnalyticsSystem 空壳应可被 World.run 调用且不抛错。
        let emptyArticle = GeneratedArticle(
            body: "", spans: [], generatorId: "test", tier: .fast)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: emptyArticle, targetLemmas: [], sourceText: nil, topic: nil))
        try world.run(AnalyticsSystem(), context: ())
    }

    // MARK: - Lemma 去重

    /// 构造含 lemma 的 batch（模拟 CSVImporter：lemma node id = lemma-<deck>-<i>）。
    private func makeLemmaBatch(deckId: String, words: [(String, String)]) -> ImportBatch {
        var nodes: [ImportBatch.NodeSpec] = [.init(id: deckId, kind: .deck, createdAt: now)]
        var texts: [TextComponent] = []
        var lemmaMetas: [LemmaMetaComponent] = []
        var scheds: [ScheduleStateComponent] = []
        var edges: [ImportBatch.EdgeSpec] = []
        for (i, w) in words.enumerated() {
            let lemmaId = "lemma-\(deckId)-\(i)"
            let cardId = "card-\(deckId)-\(i)"
            nodes.append(.init(id: lemmaId, kind: .lemma, createdAt: now))
            texts.append(TextComponent(entityId: lemmaId, textA: w.0, textB: w.1, language: nil))
            lemmaMetas.append(LemmaMetaComponent(
                entityId: lemmaId, pos: "v", phoneticUs: nil,
                phoneticUk: nil, sensesJson: nil))
            nodes.append(.init(id: cardId, kind: .card, createdAt: now))
            scheds.append(CSVImporter.makeInitialSchedule(entityId: cardId, now: now))
            edges.append(.init(id: "has-lemma-\(cardId)", srcId: deckId,
                               dstId: lemmaId, rel: .has, createdAt: now))
            edges.append(.init(id: "has-card-\(cardId)", srcId: deckId,
                               dstId: cardId, rel: .has, createdAt: now))
            edges.append(.init(id: "inst-\(cardId)", srcId: cardId,
                               dstId: lemmaId, rel: .instantiates, createdAt: now))
        }
        return ImportBatch(
            deckId: deckId, nodes: nodes, textComponents: texts,
            deckMetas: [DeckMetaComponent(entityId: deckId, name: deckId,
                                          sourceKind: "csv", sourcePath: nil, importedAt: now)],
            lemmaMetas: lemmaMetas, scheduleStates: scheds,
            edges: edges, failures: [])
    }

    /// 跨词包重复词：复用同一 Lemma，卡片各自指向它，释义多来源合并。
    func testSameLemmaAcrossDecksReused() throws {
        try world.run(ImportSystem(), context: makeLemmaBatch(
            deckId: "deck-1", words: [("abandon", "放弃")]))
        try world.run(ImportSystem(), context: makeLemmaBatch(
            deckId: "deck-2", words: [("abandon", "舍弃")]))

        // 只 1 个 Lemma（复用），2 个 card
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'card'"), 2)
        // 实际 lemma = 批内首个保留的原 id（方案 B），第二个词包复用
        let lemmaId = try XCTUnwrap(graph.findLemmaId(byTextA: "abandon"))
        XCTAssertEqual(lemmaId, "lemma-deck-1-0")
        // 两个 card 的 instantiates 边都指向同一 Lemma
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM edges WHERE rel_type = 'instantiates' AND dst_id = ?",
            [lemmaId]), 2)
        // 释义合并：两个来源各一条，不覆盖
        let defs = try graph.lemmaDefinitions(lemmaId: lemmaId)
        XCTAssertEqual(defs.count, 2)
        XCTAssertEqual(Set(defs.map(\.source)), ["deck:deck-1", "deck:deck-2"])
        XCTAssertEqual(Set(defs.map(\.definition)), ["放弃", "舍弃"])
    }

    /// 批次内变体归一：battle 与 battles 合并为同一 Lemma。
    func testVariantLemmasMergedWithinBatch() throws {
        try world.run(ImportSystem(), context: makeLemmaBatch(
            deckId: "deck-1", words: [("battle", "a"), ("battles", "b")]))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 1)
        let lemmaId = try XCTUnwrap(graph.findLemmaId(byTextA: "battle"))
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM edges WHERE rel_type = 'instantiates' AND dst_id = ?",
            [lemmaId]), 2)
    }
}

/// 测试用错误（验证事务回滚）。
enum ImportTestError: Error { case boom }
