import XCTest
import GRDB
@testable import WordRecitingApp

final class SynonymSystemTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry!
    private var graph: GraphQueries!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        registry = world.registry
        graph = world.graph
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    private func setupTwoLemmas() throws {
        for (id, text) in [("L1", "abandon"), ("L2", "forsake")] {
            try registry.insertNode(id: id, kind: .lemma, createdAt: epoch)
            try registry.upsertComponent(TextComponent(
                entityId: id, textA: text, textB: "测试释义", language: nil))
        }
    }

    // MARK: - add：插入边 + 权重组件

    func testAddCreatesMapsToEdgeAndWeightedComponent() throws {
        try setupTwoLemmas()
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 1.0, sourceType: "user"))

        // 1 条 maps_to 边 + kind=edge 的 node（共 2+1=3 个 nodes）
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'edge'"), 1)
        // 1 个 comp_edge_weighted
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_edge_weighted"), 1)

        // 权重与来源类型正确
        let weights: [EdgeWeightedComponent] = try appDB.dbWriter.read { db in
            try EdgeWeightedComponent.fetchAll(db, sql: "SELECT * FROM comp_edge_weighted")
        }
        let w = try XCTUnwrap(weights.first)
        XCTAssertEqual(w.weightDouble, 1.0)
        XCTAssertEqual(w.sourceType, "user")
    }

    // MARK: - add 幂等：同方向重复插入不增加边数，仅更新权重

    func testAddSameDirectionIsIdempotentUpdatesWeight() throws {
        try setupTwoLemmas()
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 0.5, sourceType: "user"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 1)

        // 同方向再插一次：权重应更新为 0.9，边数不变
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 0.9, sourceType: "manual"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 1)

        let weights: [EdgeWeightedComponent] = try appDB.dbWriter.read { db in
            try EdgeWeightedComponent.fetchAll(db, sql: "SELECT * FROM comp_edge_weighted")
        }
        let w = try XCTUnwrap(weights.first)
        XCTAssertEqual(w.weightDouble, 0.9)
        XCTAssertEqual(w.sourceType, "manual")
    }

    // MARK: - add 幂等：反方向也视为同一对，不重复插入

    func testAddReverseDirectionAlsoIdempotent() throws {
        try setupTwoLemmas()
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 1.0, sourceType: "user"))
        // 反方向 L2→L1 也应命中现有边，不新增
        try world.run(SynonymSystem(), context: .add(
            from: "L2", to: "L1", weight: 0.8, sourceType: "user"))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 1)
    }

    // MARK: - add 同词（from == to）直接忽略

    func testAddSameLemmaIgnored() throws {
        try setupTwoLemmas()
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L1", weight: 1.0, sourceType: "user"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 0)
    }

    // MARK: - add 两端不存在抛错（lemmaNotFound）

    func testAddMissingFromLemmaThrows() throws {
        // 只建 L2，不建 L1
        try registry.insertNode(id: "L2", kind: .lemma, createdAt: epoch)
        try registry.upsertComponent(TextComponent(
            entityId: "L2", textA: "forsake", textB: nil, language: nil))

        XCTAssertThrowsError(try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 1.0, sourceType: "user"))) { err in
            XCTAssertEqual(err as? SynonymError, .lemmaNotFound("L1"))
        }
    }

    func testAddMissingToLemmaThrows() throws {
        try registry.insertNode(id: "L1", kind: .lemma, createdAt: epoch)
        try registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))

        XCTAssertThrowsError(try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 1.0, sourceType: "user"))) { err in
            XCTAssertEqual(err as? SynonymError, .lemmaNotFound("L2"))
        }
    }

    // MARK: - removeByEdge：按 edge id 删除，CASCADE 清边与组件

    func testRemoveByEdgeCleansUp() throws {
        try setupTwoLemmas()
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 1.0, sourceType: "user"))
        let mappings = try graph.listAllSynonymMappings()
        let edgeId = try XCTUnwrap(mappings.first?.edgeId)

        try world.run(SynonymSystem(), context: .removeByEdge(edgeId: edgeId))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_edge_weighted"), 0)
        // kind=edge 的 node 也应被删除
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'edge'"), 0)
        // 两个 lemma 不受影响
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'lemma'"), 2)
    }

    // MARK: - removePair：按 lemma 对删除，正 / 反都匹配

    func testRemovePairForwardDirection() throws {
        try setupTwoLemmas()
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 1.0, sourceType: "user"))
        // L1→L2，传 removePair(L1, L2)
        try world.run(SynonymSystem(), context: .removePair(a: "L1", b: "L2"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 0)
    }

    func testRemovePairReverseDirection() throws {
        try setupTwoLemmas()
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 1.0, sourceType: "user"))
        // L1→L2，但传 removePair(L2, L1)（反向）也应删掉
        try world.run(SynonymSystem(), context: .removePair(a: "L2", b: "L1"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 0)
    }

    func testRemovePairNonexistentSilentlySucceeds() throws {
        try setupTwoLemmas()
        // 没建任何 maps_to 边，removePair 不应抛错
        try world.run(SynonymSystem(), context: .removePair(a: "L1", b: "L2"))
        // 仍 0 条边
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'maps_to'"), 0)
    }

    // MARK: - 端到端：RuleBasedGenerator 改写命中用户自定义同义词

    func testEndToEndUserDefinedSynonymUsedInRewrite() async throws {
        try setupTwoLemmas()
        // 1. 初始无同义词 → 改写不替换
        let gen = RuleBasedGenerator()
        let before = try await gen.generate(
            mode: .rewrite,
            sourceText: "I will abandon this project.",
            targetLemmas: ["L2"],  // 目标是 L2(forsake)
            constraints: GenerationConstraints(synonymDistance: 0.4),
            graph: graph)
        // 没有 maps_to 边，abandon 不应被替换为 forsake
        XCTAssertEqual(before.body, "I will abandon this project.")

        // 2. 添加 L1→L2 (abandon → forsake) 同义词
        try world.run(SynonymSystem(), context: .add(
            from: "L1", to: "L2", weight: 1.0, sourceType: "user"))

        // 3. 再次改写 → abandon 应被替换为 forsake
        let after = try await gen.generate(
            mode: .rewrite,
            sourceText: "I will abandon this project.",
            targetLemmas: ["L2"],
            constraints: GenerationConstraints(synonymDistance: 0.4),
            graph: graph)
        XCTAssertEqual(after.body, "I will forsake this project.")
    }
}
