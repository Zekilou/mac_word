import XCTest
import GRDB
@testable import WordRecitingApp

final class ContentGenSystemTests: XCTestCase {

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

    /// 造 1 个目标 Lemma B + 同义词 maps_to A→B
    private func setupLemmaB() throws {
        for (id, text) in [("A", "abandon"), ("B", "forsake")] {
            try registry.insertNode(id: id, kind: .lemma, createdAt: epoch)
            try registry.upsertComponent(TextComponent(
                entityId: id, textA: text, textB: nil, language: nil))
        }
        try registry.insertEdge(id: "e-ab", srcId: "A", dstId: "B", rel: .mapsTo, createdAt: epoch)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: "e-ab", weightDouble: 0.9, sourceType: "user"))
    }

    // MARK: - 核心落库

    func testPersistsArticleNodeAndText() throws {
        let body = "I will forsake this project."
        let article = GeneratedArticle(
            body: body, spans: [], generatorId: "rule-based", tier: .fast)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: [], sourceText: nil, topic: nil))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'article'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_text"), 1)
        let text: TextComponent? = try registry.fetchComponents(
            for: try fetchArticleId(), table: "comp_text")
        XCTAssertEqual(text?.textA, body)
    }

    func testPersistsGenerationMeta() throws {
        let article = GeneratedArticle(
            body: "body", spans: [], generatorId: "rule-based", tier: .fast)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: ["B"],
            sourceText: "original text", topic: "synonym practice"))

        let aid = try fetchArticleId()
        let meta: GenerationMetaComponent? = try registry.fetchComponents(
            for: aid, table: "comp_generation_meta")
        XCTAssertEqual(meta?.generatorId, "rule-based")
        XCTAssertEqual(meta?.mode, "rewrite")
        XCTAssertEqual(meta?.qualityTier, "fast")
        XCTAssertEqual(meta?.sourceText, "original text")
        XCTAssertEqual(meta?.topic, "synonym practice")
        XCTAssertNil(meta?.promptHash)
    }

    // MARK: - highlighted_in 边 + comp_edge_span

    func testHighlightedInEdgesAndSpanOffsets() throws {
        try setupLemmaB()
        let body = "I will forsake this project."
        // "forsake" 在 body 中偏移 7..<14
        let span = SpanInfo(
            start: 7, end: 14, isTarget: true,
            lemmaId: "B", surfaceForm: "forsake",
            replacedFrom: "abandon", weight: 0.9, sourceType: "user")
        let article = GeneratedArticle(
            body: body, spans: [span], generatorId: "rule-based", tier: .fast)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: ["B"], sourceText: "I will abandon this project.", topic: nil))

        let aid = try fetchArticleId()

        // GraphQueries 反查 highlighted_in 邻居
        let neighbors = try graph.neighbors(of: aid, rel: .highlightedIn)
        XCTAssertEqual(neighbors.count, 1)
        XCTAssertEqual(neighbors.first?.srcId, "B")
        XCTAssertEqual(neighbors.first?.dstId, aid)

        // comp_edge_span 偏移与 body 吻合
        let spanComps: [EdgeSpanComponent] = try appDB.dbWriter.read { db in
            try EdgeSpanComponent.fetchAll(db, sql: "SELECT * FROM comp_edge_span")
        }
        XCTAssertEqual(spanComps.count, 1)
        let sp = try XCTUnwrap(spanComps.first)
        XCTAssertEqual(sp.surfaceForm, "forsake")
        XCTAssertEqual(sp.start, 7)
        XCTAssertEqual(sp.end, 14)
        XCTAssertEqual(sp.isTarget, true)
        // 偏移确实对应 body 中的 "forsake"
        let bodyChars = Array(body)
        XCTAssertEqual(String(bodyChars[sp.start!..<sp.end!]), "forsake")
    }

    // MARK: - comp_edge_weighted（替换型 span）

    func testEdgeWeightedForReplacementSpan() throws {
        try setupLemmaB()
        let span = SpanInfo(
            start: 0, end: 7, isTarget: true,
            lemmaId: "B", surfaceForm: "forsake",
            replacedFrom: "abandon", weight: 0.9, sourceType: "user")
        let article = GeneratedArticle(
            body: "forsake all.", spans: [span], generatorId: "rule-based", tier: .fast)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: ["B"], sourceText: nil, topic: nil))

        let weights: [EdgeWeightedComponent] = try appDB.dbWriter.read { db in
            try EdgeWeightedComponent.fetchAll(
                db, sql: "SELECT * FROM comp_edge_weighted WHERE entity_id LIKE 'hl-%'")
        }
        XCTAssertEqual(weights.count, 1)
        XCTAssertEqual(weights.first?.weightDouble, 0.9)
        XCTAssertEqual(weights.first?.sourceType, "user")
    }

    // MARK: - 非替换型 span 不写 comp_edge_weighted

    func testDirectTargetSpanNoWeight() throws {
        try setupLemmaB()
        let span = SpanInfo(
            start: 0, end: 7, isTarget: true,
            lemmaId: "B", surfaceForm: "forsake",
            replacedFrom: nil)
        let article = GeneratedArticle(
            body: "forsake all.", spans: [span], generatorId: "rule-based", tier: .fast)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: ["B"], sourceText: nil, topic: nil))

        // 直接出现的目标词无 weight → 不写 comp_edge_weighted（仅查 highlighted_in 边上的）
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_edge_weighted WHERE entity_id LIKE 'hl-%'"), 0)
        // 但仍有 highlighted_in 边 + comp_edge_span
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'highlighted_in'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_edge_span"), 1)
    }

    // MARK: - 多 span

    func testMultipleSpansPersist() throws {
        try setupLemmaB()
        // 额外造 Lemma D
        try registry.insertNode(id: "D", kind: .lemma, createdAt: epoch)
        try registry.upsertComponent(TextComponent(
            entityId: "D", textA: "tiny", textB: nil, language: nil))

        let body = "forsake the tiny cat."
        let spans = [
            SpanInfo(start: 0, end: 6, isTarget: true, lemmaId: "B",
                     surfaceForm: "forsake", replacedFrom: "abandon", weight: 0.9, sourceType: "user"),
            SpanInfo(start: 11, end: 15, isTarget: true, lemmaId: "D",
                     surfaceForm: "tiny", replacedFrom: "small", weight: 0.8, sourceType: "wordnet"),
        ]
        let article = GeneratedArticle(
            body: body, spans: spans, generatorId: "rule-based", tier: .fast)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: ["B", "D"], sourceText: nil, topic: nil))

        let aid = try fetchArticleId()
        let neighbors = try graph.neighbors(of: aid, rel: .highlightedIn)
        XCTAssertEqual(neighbors.count, 2)
        let lemmaIds = Set(neighbors.map { $0.srcId })
        XCTAssertEqual(lemmaIds, Set(["B", "D"]))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_edge_span"), 2)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_edge_weighted WHERE entity_id LIKE 'hl-%'"), 2)
    }

    // MARK: - 空 spans

    func testEmptySpansCreatesArticleOnly() throws {
        let article = GeneratedArticle(
            body: "no targets here.", spans: [], generatorId: "rule-based", tier: .fast)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: [], sourceText: nil, topic: nil))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'article'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_text"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_generation_meta"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edges WHERE rel_type = 'highlighted_in'"), 0)
    }

    // MARK: - 事务原子性

    func testRollsBackOnDuplicateEdgeId() throws {
        // 预插入一个冲突的 article node id 是不行的（UUID 随机），
        // 但可以测试 lemma 不存在时 FK 约束触发回滚。
        let span = SpanInfo(
            start: 0, end: 5, isTarget: true,
            lemmaId: "nonexistent", surfaceForm: "hello",
            replacedFrom: nil)
        let article = GeneratedArticle(
            body: "hello", spans: [span], generatorId: "rule-based", tier: .fast)

        // lemma "nonexistent" 不存在 → insertEdge 时 FK 约束失败 → 回滚
        XCTAssertThrowsError(try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: ["nonexistent"], sourceText: nil, topic: nil)))

        // 回滚后不应有任何 article 节点
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'article'"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_text"), 0)
    }

    // MARK: - 端到端：RuleBasedGenerator → ContentGenSystem

    func testEndToEndGeneratorToSystem() async throws {
        try setupLemmaB()
        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "I will abandon this project.",
            targetLemmas: ["B"],
            constraints: GenerationConstraints(),
            graph: graph)

        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: article, targetLemmas: ["B"],
            sourceText: "I will abandon this project.", topic: nil))

        let aid = try fetchArticleId()
        // 文章正文
        let text: TextComponent? = try registry.fetchComponents(for: aid, table: "comp_text")
        XCTAssertEqual(text?.textA, "I will forsake this project.")
        // 生成器 id
        let meta: GenerationMetaComponent? = try registry.fetchComponents(for: aid, table: "comp_generation_meta")
        XCTAssertEqual(meta?.generatorId, "rule-based")
        // highlighted_in 邻居
        let neighbors = try graph.neighbors(of: aid, rel: .highlightedIn)
        XCTAssertEqual(neighbors.count, 1)
        XCTAssertEqual(neighbors.first?.srcId, "B")
    }

    // MARK: - 辅助

    private func fetchArticleId() throws -> EntityID {
        let id = try appDB.dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM nodes WHERE kind = 'article' ORDER BY created_at DESC LIMIT 1")
        }
        return try XCTUnwrap(id)
    }
}
