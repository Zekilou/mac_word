import XCTest
import GRDB
@testable import WordRecitingApp

final class RuleBasedGeneratorTests: XCTestCase {

    private var appDB: AppDatabase!
    private var registry: EntityRegistry!
    private var graph: GraphQueries!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        registry = EntityRegistry(database: appDB)
        graph = GraphQueries(database: appDB)
    }

    // 造 3 个 LemmaNode(A="abandon", B="forsake", C="leave") + maps_to(A→B, weight=0.9, user)
    private func setupLemmas() throws {
        for (id, text) in [("A", "abandon"), ("B", "forsake"), ("C", "leave")] {
            try registry.insertNode(id: id, kind: .lemma, createdAt: epoch)
            try registry.upsertComponent(TextComponent(
                entityId: id, textA: text, textB: nil, language: nil))
        }
        try registry.insertEdge(id: "e-ab", srcId: "A", dstId: "B", rel: .mapsTo, createdAt: epoch)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: "e-ab", weightDouble: 0.9, sourceType: "user"))
    }

    // MARK: - 核心替换

    func testRewriteReplacesAbandonWithForsake() async throws {
        try setupLemmas()
        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "I will abandon this project.",
            targetLemmas: ["B"],
            constraints: GenerationConstraints(),
            graph: graph)

        XCTAssertEqual(article.body, "I will forsake this project.")
        XCTAssertEqual(article.spans.count, 1)
        let span = try XCTUnwrap(article.spans.first)
        XCTAssertTrue(span.isTarget)
        XCTAssertEqual(span.lemmaId, "B")
        XCTAssertEqual(span.surfaceForm, "forsake")
        XCTAssertEqual(span.replacedFrom, "abandon")
        // 偏移与 body 吻合
        let bodyChars = Array(article.body)
        XCTAssertEqual(String(bodyChars[span.start..<span.end]), "forsake")
    }

    // MARK: - 目标词直接出现（不替换）

    func testDirectTargetWordRecordsSpanWithoutReplacement() async throws {
        try setupLemmas()
        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "I will forsake this idea.",
            targetLemmas: ["B"],
            constraints: GenerationConstraints(),
            graph: graph)

        XCTAssertEqual(article.body, "I will forsake this idea.")
        XCTAssertEqual(article.spans.count, 1)
        let span = try XCTUnwrap(article.spans.first)
        XCTAssertEqual(span.lemmaId, "B")
        XCTAssertEqual(span.surfaceForm, "forsake")
        XCTAssertNil(span.replacedFrom, "目标词直接出现时 replacedFrom 应为 nil")
    }

    // MARK: - 无匹配词不产生 span

    func testNonTargetWordProducesNoSpan() async throws {
        try setupLemmas()
        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "I will leave now.",
            targetLemmas: ["B"],
            constraints: GenerationConstraints(),
            graph: graph)

        // leave 对应 Lemma C，C 不在目标列表且无 maps_to 到 B
        XCTAssertEqual(article.body, "I will leave now.")
        XCTAssertEqual(article.spans.count, 0)
    }

    // MARK: - 词形还原（abandons → abandon → forsake）

    func testLemmatizationHandlesPlural() async throws {
        try setupLemmas()
        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "He abandons the plan.",
            targetLemmas: ["B"],
            constraints: GenerationConstraints(),
            graph: graph)

        // "abandons" → strip -s → "abandon" → 匹配 Lemma A → 同义词 B
        // MVP 不做屈折恢复，surfaceForm = synonym.text_a = "forsake"
        XCTAssertEqual(article.body, "He forsake the plan.")
        XCTAssertEqual(article.spans.count, 1)
        XCTAssertEqual(article.spans.first?.surfaceForm, "forsake")
        XCTAssertEqual(article.spans.first?.replacedFrom, "abandons")
    }

    // MARK: - 权重过滤

    func testWeightBelowThresholdNoReplacement() async throws {
        try setupLemmas()
        let gen = RuleBasedGenerator()
        // synonymDistance=0.95 > 0.9 → 同义词被过滤
        var constraints = GenerationConstraints()
        constraints.synonymDistance = 0.95
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "I will abandon this.",
            targetLemmas: ["B"],
            constraints: constraints,
            graph: graph)

        XCTAssertEqual(article.body, "I will abandon this.")
        XCTAssertEqual(article.spans.count, 0)
    }

    // MARK: - source_type 优先级（user > wordnet）

    func testSourceTypePriorityUserOverWordnet() async throws {
        // A→B(user, 0.5) + A→C(wordnet, 0.9)；目标=[B,C]
        // C weight 更高但 user 优先级更高 → 选 B
        try registry.insertNode(id: "A", kind: .lemma, createdAt: epoch)
        try registry.insertNode(id: "B", kind: .lemma, createdAt: epoch)
        try registry.insertNode(id: "C", kind: .lemma, createdAt: epoch)
        for (id, text) in [("A", "abandon"), ("B", "forsake"), ("C", "leave")] {
            try registry.upsertComponent(TextComponent(
                entityId: id, textA: text, textB: nil, language: nil))
        }
        try registry.insertEdge(id: "e-ab", srcId: "A", dstId: "B", rel: .mapsTo, createdAt: epoch)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: "e-ab", weightDouble: 0.5, sourceType: "user"))
        try registry.insertEdge(id: "e-ac", srcId: "A", dstId: "C", rel: .mapsTo, createdAt: epoch)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: "e-ac", weightDouble: 0.9, sourceType: "wordnet"))

        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "I abandon this.",
            targetLemmas: ["B", "C"],
            constraints: GenerationConstraints(),
            graph: graph)

        // user 优先 → 选 B(forsake) 而非 C(leave)
        XCTAssertEqual(article.spans.first?.lemmaId, "B")
        XCTAssertEqual(article.spans.first?.surfaceForm, "forsake")
    }

    // MARK: - 大小写保持

    func testCapitalizedWordKeepsCase() async throws {
        try setupLemmas()
        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "Abandon all hope.",
            targetLemmas: ["B"],
            constraints: GenerationConstraints(),
            graph: graph)

        // "Abandon" 首字母大写 → 替换为 "Forsake"
        XCTAssertEqual(article.body, "Forsake all hope.")
        XCTAssertEqual(article.spans.first?.surfaceForm, "Forsake")
    }

    // MARK: - 空源文

    func testEmptySourceTextReturnsEmpty() async throws {
        try setupLemmas()
        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "",
            targetLemmas: ["B"],
            constraints: GenerationConstraints(),
            graph: graph)

        XCTAssertEqual(article.body, "")
        XCTAssertEqual(article.spans.count, 0)
    }

    // MARK: - generate 模式不处理

    func testGenerateModeReturnsSourceAsIs() async throws {
        try setupLemmas()
        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "I will abandon this.",
            targetLemmas: ["B"],
            constraints: GenerationConstraints(),
            graph: graph)

        // generate 模式不做改写
        XCTAssertEqual(article.body, "I will abandon this.")
        XCTAssertEqual(article.spans.count, 0)
    }

    // MARK: - 协议元数据

    func testIdentifierAndTier() {
        XCTAssertEqual(RuleBasedGenerator.identifier, "rule-based")
        XCTAssertEqual(RuleBasedGenerator.tier, .fast)
    }

    // MARK: - 多目标词多替换

    func testMultipleReplacementsInOnePassage() async throws {
        // A="big"→B="large"(user,0.9), C="small"→D="tiny"(user,0.9)
        for (id, text) in [("A", "big"), ("B", "large"), ("C", "small"), ("D", "tiny")] {
            try registry.insertNode(id: id, kind: .lemma, createdAt: epoch)
            try registry.upsertComponent(TextComponent(
                entityId: id, textA: text, textB: nil, language: nil))
        }
        try registry.insertEdge(id: "e-ab", srcId: "A", dstId: "B", rel: .mapsTo, createdAt: epoch)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: "e-ab", weightDouble: 0.9, sourceType: "user"))
        try registry.insertEdge(id: "e-cd", srcId: "C", dstId: "D", rel: .mapsTo, createdAt: epoch)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: "e-cd", weightDouble: 0.9, sourceType: "user"))

        let gen = RuleBasedGenerator()
        let article = try await gen.generate(
            mode: .rewrite,
            sourceText: "The big cat chased the small mouse.",
            targetLemmas: ["B", "D"],
            constraints: GenerationConstraints(),
            graph: graph)

        XCTAssertEqual(article.body, "The large cat chased the tiny mouse.")
        XCTAssertEqual(article.spans.count, 2)
        let ids = Set(article.spans.compactMap { $0.lemmaId })
        XCTAssertEqual(ids, Set(["B", "D"]))
    }

    // MARK: - GraphQueries.findLemmaId / synonyms 单元测试

    func testGraphFindLemmaId() throws {
        try setupLemmas()
        XCTAssertEqual(try graph.findLemmaId(byTextA: "abandon"), "A")
        XCTAssertEqual(try graph.findLemmaId(byTextA: "forsake"), "B")
        XCTAssertNil(try graph.findLemmaId(byTextA: "nonexistent"))
    }

    func testGraphSynonyms() throws {
        try setupLemmas()
        let syns = try graph.synonyms(of: "A")
        XCTAssertEqual(syns.count, 1)
        XCTAssertEqual(syns.first?.lemmaId, "B")
        XCTAssertEqual(syns.first?.surfaceForm, "forsake")
        XCTAssertEqual(syns.first?.weight, 0.9)
        XCTAssertEqual(syns.first?.sourceType, "user")
    }
}
