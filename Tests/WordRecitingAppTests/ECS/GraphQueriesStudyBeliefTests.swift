import XCTest
@testable import WordRecitingApp

/// 复习相关查询要把 BKT 后验一起带出来。
final class GraphQueriesStudyBeliefTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func seedCard(lemmaId: String, cardId: String, text: String, belief: Double?) throws {
        let now = Date()
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: now)
        try world.registry.insertNode(id: cardId, kind: .card, createdAt: now)
        try world.registry.upsertComponent(TextComponent(
            entityId: lemmaId, textA: text, textB: "释义", language: nil))
        try world.registry.insertEdge(id: "edge-\(cardId)", srcId: cardId, dstId: lemmaId,
                                      rel: .instantiates, createdAt: now)
        if let belief {
            try world.registry.upsertComponent(MasteryBeliefComponent(
                entityId: lemmaId, belief: belief, opportunities: 2,
                lastEventAt: nil, updatedAt: now, paramsVersion: "bkt-1"))
        }
    }

    func testDueCardsCarriesBelief() throws {
        try seedCard(lemmaId: "L1", cardId: "C1", text: "abandon", belief: 0.42)

        let cards = try world.graph.dueCards()

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].belief ?? 0, 0.42, accuracy: 0.0001)
    }

    func testCardForLemmaCarriesBelief() throws {
        try seedCard(lemmaId: "L1", cardId: "C1", text: "abandon", belief: 0.42)

        XCTAssertEqual(try world.graph.cardForLemma("L1")?.belief ?? 0, 0.42, accuracy: 0.0001)
    }

    func testBeliefIsNilWithoutModelData() throws {
        try seedCard(lemmaId: "L2", cardId: "C2", text: "ability", belief: nil)

        XCTAssertNil(try world.graph.dueCards().first?.belief)
    }

    func testDueCardsExcludesHighBeliefWords() throws {
        try seedCard(lemmaId: "L1", cardId: "C1", text: "abandon", belief: 0.95)

        XCTAssertTrue(try world.graph.dueCards().isEmpty)
    }

    func testDueCardsKeepsLowBeliefWords() throws {
        try seedCard(lemmaId: "L2", cardId: "C2", text: "ability", belief: 0.40)

        XCTAssertEqual(try world.graph.dueCards().count, 1)
    }

    func testDueCardsStillExcludesExplicitlyKnownWords() throws {
        try seedCard(lemmaId: "L3", cardId: "C3", text: "zebra", belief: 0.30)
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L3", mastery: 2.0, seenCount: 0,
            source: "init", updatedAt: Date()))

        XCTAssertTrue(try world.graph.dueCards().isEmpty)
    }

    // MARK: - 到期口径一致性（studyStats.dueCount 必须与 dueCards 同口径）

    func testDueCutoffsAreSharedConstants() {
        XCTAssertEqual(GraphQueries.dueBeliefCutoff, 0.90, accuracy: 0.0001)
        XCTAssertEqual(GraphQueries.dueMasteryCutoff, 1.999, accuracy: 0.0001)
    }

    func testStudyStatsDueCountExcludesHighBeliefWords() throws {
        try seedCard(lemmaId: "L1", cardId: "C1", text: "abandon", belief: 0.95)
        try seedCard(lemmaId: "L2", cardId: "C2", text: "ability", belief: 0.40)

        XCTAssertEqual(try world.graph.dueCards().count, 1)
        XCTAssertEqual(try world.graph.studyStats().dueCount, 1)
    }

    func testStudyStatsDueCountExcludesExplicitlyKnownWords() throws {
        try seedCard(lemmaId: "L3", cardId: "C3", text: "zebra", belief: 0.30)
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L3", mastery: 2.0, seenCount: 0,
            source: "init", updatedAt: Date()))

        XCTAssertEqual(try world.graph.studyStats().dueCount, 0)
    }

    func testQueueDueDatesFollowsSameCutoff() throws {
        try seedCard(lemmaId: "L1", cardId: "C1", text: "abandon", belief: 0.95)
        try seedCard(lemmaId: "L2", cardId: "C2", text: "ability", belief: 0.40)

        XCTAssertEqual(try world.graph.queueDueDates().count, 1)
    }

    /// 回归：**没有 instantiates 边**的卡片（CSV `front,back` 导入）必须三处口径一致。
    /// @ai: 旧实现里 dueCards 用 INNER JOIN、dueCount/queueDueDates 用 LEFT JOIN：
    ///      这类卡片会被统计为「今日到期」却永远不进复习队列，
    ///      首页/背诵页显示「今日到期 1」而队列为空。
    func testDueQueueAndCountAgreeForCardWithoutInstantiatesEdge() throws {
        let now = Date()
        // CSV front/back 分支：只建 card 节点 + 自身 comp_text + has 边（无 lemma、无 instantiates）
        try world.registry.insertNode(id: "deck-d", kind: .deck, createdAt: now)
        try world.registry.insertNode(id: "card-d-hello", kind: .card, createdAt: now)
        try world.registry.upsertComponent(TextComponent(
            entityId: "card-d-hello", textA: "hello", textB: "你好", language: nil))
        try world.registry.insertEdge(id: "has-d-hello", srcId: "deck-d", dstId: "card-d-hello",
                                      rel: .has, createdAt: now)
        try world.registry.upsertComponent(ScheduleStateComponent(
            entityId: "card-d-hello", stability: 0, difficulty: 0, dueAt: now,
            intervalDays: nil, reps: 0, lapses: 0, lastRating: nil,
            lastReviewedAt: nil, schedulerId: nil, queue: "new", customDataJson: nil))

        let cards = try world.graph.dueCards()
        let stats = try world.graph.studyStats()
        let queueDates = try world.graph.queueDueDates()

        XCTAssertEqual(cards.count, 1, "无 instantiates 边的卡也应进队列（词面取自自身 comp_text）")
        XCTAssertEqual(cards[0].text, "hello")
        XCTAssertEqual(stats.dueCount, cards.count, "dueCount 必须与队列行数一致")
        XCTAssertEqual(queueDates.count, cards.count, "queueDueDates 必须与队列行数一致")
    }

    /// 回归：到期队列顺序必须可复现（同一 due_at 用 card_id 兜底排序）。
    func testDueCardsOrderIsDeterministic() throws {
        for i in 0..<8 {
            try seedCard(lemmaId: "L\(i)", cardId: "C\(i)", text: "word\(i)", belief: 0.40)
        }
        let first = try world.graph.dueCards(limit: 100).map(\.cardId)
        for _ in 0..<5 {
            XCTAssertEqual(try world.graph.dueCards(limit: 100).map(\.cardId), first,
                           "同一数据下队列顺序必须稳定")
        }
    }
}
