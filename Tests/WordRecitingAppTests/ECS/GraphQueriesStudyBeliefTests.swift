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
}
