import XCTest
import GRDB
@testable import WordRecitingApp

/// 造文（主路径）与卡片浏览查询测试：
/// 1. RuleBasedGenerator .generate：给定主题 + 目标词 → 输出包含全部目标词的文章 + spans
/// 2. ContentGenSystem 以 .generate 模式落库 → recentArticles(.generate) 可回读
/// 3. cardsInDeck / lemmaDetail 查询（卡片浏览器数据源）
final class GenerateAndCardBrowserTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
    }

    // MARK: - 准备一个小词库（abandon / battle / happy 三个 lemma + 3 张卡 + 1 deck）

    private func seedSmallDeck() throws -> (deckId: EntityID, abandonId: EntityID, battleId: EntityID) {
        let now = Date()
        let deckId = "deck-1"
        let lemmaIds = ["lemma-1", "lemma-2", "lemma-3"]
        let cardIds = ["card-1", "card-2", "card-3"]
        let words = ["abandon", "battle", "happy"]
        let definitions = ["give up", "fight", "glad"]

        var nodes: [ImportBatch.NodeSpec] = [
            .init(id: deckId, kind: .deck, createdAt: now)
        ]
        for id in lemmaIds {
            nodes.append(.init(id: id, kind: .lemma, createdAt: now))
        }
        for id in cardIds {
            nodes.append(.init(id: id, kind: .card, createdAt: now))
        }

        let deckMetas = [DeckMetaComponent(
            entityId: deckId, name: "TestDeck", sourceKind: "csv",
            sourcePath: nil, importedAt: now)]

        let textComps = (0..<3).map { i in
            // 与 Anki 导入一致：词面 text_a 放在 Lemma 节点上（findLemmaId 查 kind='lemma'）。
            TextComponent(
                entityId: lemmaIds[i], textA: words[i],
                textB: definitions[i], language: "en")
        }

        let lemmaMetas = [
            LemmaMetaComponent(entityId: "lemma-1", pos: "v", phoneticUs: nil, phoneticUk: nil, sensesJson: nil),
            LemmaMetaComponent(entityId: "lemma-2", pos: "n", phoneticUs: nil, phoneticUk: nil, sensesJson: nil),
            LemmaMetaComponent(entityId: "lemma-3", pos: "adj", phoneticUs: nil, phoneticUk: nil, sensesJson: nil),
        ]

        // 卡片 → Lemma 的 instantiates 边 + deck 的 has 边
        // 注意：card 的词面（text_a）在 card 上，需经 instantiates 边 JOIN 到 lemma，
        // 所以查询要 JOIN instantiates 到 lemma 的 comp_text。
        // 这里词面直接放 card（与 Anki 一致：card 有 text_a），lemma 节点只存元数据。
        var edges: [ImportBatch.EdgeSpec] = []
        for (i, cid) in cardIds.enumerated() {
            edges.append(.init(id: "has-\(cid)", srcId: deckId, dstId: cid, rel: .has, createdAt: now))
            edges.append(.init(id: "inst-\(cid)", srcId: cid, dstId: lemmaIds[i], rel: .instantiates, createdAt: now))
        }

        let scheduleStates = [
            ScheduleStateComponent(
                entityId: "card-1", stability: 1, difficulty: 5, dueAt: Date(),
                intervalDays: 1, reps: 1, lapses: 0, lastRating: 3, lastReviewedAt: nil),
        ]

        let batch = ImportBatch(
            deckId: deckId, nodes: nodes, textComponents: textComps,
            deckMetas: deckMetas, lemmaMetas: lemmaMetas,
            scheduleStates: scheduleStates, edges: edges, failures: [])
        try world.run(ImportSystem(), context: batch)
        return (deckId, "lemma-1", "lemma-2")
    }

    // MARK: - 造文：RuleBasedGenerator .generate 生成包含目标词的文章

    func testGenerateModeProducesArticleContainingAllTargetWords() async throws {
        let seeded = try seedSmallDeck()

        let gen = RuleBasedGenerator()
        let result = try await gen.generate(
            mode: .generate,
            sourceText: "科技趋势",
            targetLemmas: [seeded.abandonId, seeded.battleId],
            constraints: GenerationConstraints(),
            graph: graph)

        // 1. 文章非空，且包含全部目标词
        XCTAssertFalse(result.body.isEmpty)
        XCTAssertTrue(result.body.lowercased().contains("abandon"), "正文应包含 abandon")
        XCTAssertTrue(result.body.lowercased().contains("battle"), "正文应包含 battle")

        // 2. spans 覆盖全部目标词（isTarget=true）
        let targetIds = Set(result.spans.compactMap { $0.lemmaId })
        XCTAssertTrue(targetIds.contains(seeded.abandonId))
        XCTAssertTrue(targetIds.contains(seeded.battleId))
        XCTAssertTrue(result.spans.allSatisfy { $0.isTarget })

        // 3. span 偏移应落在 body 内
        for span in result.spans {
            XCTAssertGreaterThanOrEqual(span.start, 0)
            XCTAssertLessThanOrEqual(span.end, result.body.count)
        }
    }

    // MARK: - 落库：ContentGenSystem .generate 模式 → recentArticles(.generate) 可回读

    func testGenerateModePersistsAndReadsBack() async throws {
        let seeded = try seedSmallDeck()

        let gen = RuleBasedGenerator()
        let result = try await gen.generate(
            mode: .generate,
            sourceText: "环保",
            targetLemmas: [seeded.abandonId],
            constraints: GenerationConstraints(),
            graph: graph)

        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: result,
            targetLemmas: [seeded.abandonId],
            sourceText: "环保",
            topic: "环保",
            mode: .generate))

        // generate 历史应包含这篇文章
        let recent = try graph.recentArticles(mode: .generate, limit: 10)
        XCTAssertGreaterThanOrEqual(recent.count, 1)
        let latest = try XCTUnwrap(recent.first)
        let stored = try XCTUnwrap(graph.loadArticle(id: latest.id))
        XCTAssertEqual(stored.body, result.body)
        // span 也应回读
        XCTAssertGreaterThanOrEqual(stored.spans.count, 1)
        XCTAssertTrue(stored.spans.contains { $0.lemmaId == seeded.abandonId })
    }

    // MARK: - 卡片浏览：cardsInDeck 返回词+释义+复习状态

    func testCardsInDeckReturnsWordsWithDefinitions() async throws {
        let seeded = try seedSmallDeck()

        let cards = try graph.cardsInDeck(seeded.deckId)
        XCTAssertEqual(cards.count, 3)

        let abandonCard = try XCTUnwrap(cards.first(where: { $0.plainText == "abandon" }))
        XCTAssertEqual(abandonCard.definition, "give up")
        XCTAssertEqual(abandonCard.lemmaId, seeded.abandonId)

        // card-1 有 schedule state
        let firstCard = try XCTUnwrap(cards.first(where: { $0.cardId == "card-1" }))
        XCTAssertNotNil(firstCard.dueAt)
        XCTAssertEqual(firstCard.reps, 1)
    }

    // MARK: - 数据统一：卡片侧带出全局掌握度（唯一数据源 comp_user_known）

    /// @ai: 一个词一份掌握度（挂 Lemma，comp_user_known）——cardsInDeck / dueCards / cardForLemma
    ///      必须 JOIN 带出 mastery/seenCount，词包展示与词汇 Tab 同口径。
    func testCardsCarryGlobalMastery() async throws {
        let seeded = try seedSmallDeck()

        // 全局标记：abandon=会(2.0)、battle=不会(1.0)、happy 不标记（无记录）
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: seeded.abandonId, source: "test"))
        try world.run(UserKnownSystem(), context: .markUnknown(lemmaId: seeded.battleId, source: "test"))

        // cardsInDeck（卡片浏览数据源）带出掌握度
        let cards = try graph.cardsInDeck(seeded.deckId)
        XCTAssertEqual(cards.count, 3)
        let abandon = try XCTUnwrap(cards.first(where: { $0.plainText == "abandon" }))
        XCTAssertEqual(abandon.mastery, 2.0, "已会词应在卡片侧显示会")
        let battle = try XCTUnwrap(cards.first(where: { $0.plainText == "battle" }))
        XCTAssertEqual(battle.mastery, 1.0, "不会词应在卡片侧显示不会")
        let happy = try XCTUnwrap(cards.first(where: { $0.plainText == "happy" }))
        XCTAssertNil(happy.mastery, "未标记词保持无记录")
        XCTAssertEqual(happy.seenCount, 0)

        // dueCards（背诵队列数据源）排除已会词：card-1(已会) 不出队，不会/无记录保留
        let due = try graph.dueCards(limit: 100)
        XCTAssertFalse(due.contains { $0.cardId == "card-1" }, "已会词不应进背诵队列")
        XCTAssertTrue(due.contains { $0.cardId == "card-2" && $0.mastery == 1.0 })
        XCTAssertTrue(due.contains { $0.cardId == "card-3" && $0.mastery == nil })

        // studyStats.dueCount 与队列口径一致（排除已会）
        let stats = try graph.studyStats()
        XCTAssertEqual(stats.dueCount, 2, "到期统计应排除已会词")

        // cardForLemma（阅读评分数据源）同样带出
        let byLemma = try XCTUnwrap(graph.cardForLemma(seeded.abandonId))
        XCTAssertEqual(byLemma.mastery, 2.0)
    }

    // MARK: - 背诵队列排除已会词：用户确认会的词不再要求背诵

    /// @ai: 用户需求——已确认会的词（mastery ≥ 1.999）不进背诵队列（含到期统计）。
    func testDueCardsExcludesKnownWords() async throws {
        let seeded = try seedSmallDeck()
        // 三词三种状态：abandon=会、battle=不会、happy=学习中(1.5)
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: seeded.abandonId, source: "test"))
        try world.run(UserKnownSystem(), context: .markUnknown(lemmaId: seeded.battleId, source: "test"))
        try world.run(UserKnownSystem(), context: .adjust(lemmaId: "lemma-3", delta: 0.5, source: "test"))

        let due = try graph.dueCards(limit: 100)
        XCTAssertEqual(due.count, 2)
        XCTAssertTrue(due.contains { $0.lemmaId == seeded.battleId }, "不会词保留")
        XCTAssertTrue(due.contains { $0.lemmaId == "lemma-3" }, "学习中词保留（还需背诵）")
        XCTAssertFalse(due.contains { $0.lemmaId == seeded.abandonId }, "已会词排除")

        let stats = try graph.studyStats()
        XCTAssertEqual(stats.dueCount, 2)
    }

    // MARK: - 详情：lemmaDetail 返回释义 + 同义词 + 出现过的文章

    func testLemmaDetailReturnsSynonymAndArticleHits() async throws {
        let seeded = try seedSmallDeck()

        // 先建一个同义词：abandon → battle（user）
        try world.run(SynonymSystem(), context: .add(
            from: seeded.abandonId, to: seeded.battleId, weight: 1.0, sourceType: "user"))

        // 生成一篇文章并落库（battle 出现在文中）
        let gen = RuleBasedGenerator()
        let result = try await gen.generate(
            mode: .generate,
            sourceText: "主题",
            targetLemmas: [seeded.battleId],
            constraints: GenerationConstraints(),
            graph: graph)
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: result,
            targetLemmas: [seeded.battleId],
            sourceText: "主题",
            topic: "主题",
            mode: .generate))

        let detail = try XCTUnwrap(graph.lemmaDetail(seeded.abandonId))
        XCTAssertEqual(detail.definition, "give up")
        XCTAssertEqual(detail.pos, "v")
        // 同义词
        XCTAssertTrue(detail.synonyms.contains { $0.lemmaId == seeded.battleId })
        // battle 的词应出现在文章里 → 通过 highlighted_in 边查到文章命中
        let battleDetail = try XCTUnwrap(graph.lemmaDetail(seeded.battleId))
        XCTAssertGreaterThanOrEqual(battleDetail.articles.count, 1)
    }
}
