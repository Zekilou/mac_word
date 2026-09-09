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
}
