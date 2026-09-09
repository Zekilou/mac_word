import XCTest
@testable import WordRecitingApp

final class GraphQueriesMasteryTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries { world.graph }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    func testMasteryBeliefQueries() throws {
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.62, opportunities: 3,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        XCTAssertEqual(try graph.masteryBelief(lemmaId: "L1") ?? 0, 0.62, accuracy: 0.0001)
        XCTAssertNil(try graph.masteryBelief(lemmaId: "missing"))
        XCTAssertEqual(try graph.allMasteryBeliefs().count, 1)
    }

    func testRecordedLemmaCarriesBelief() throws {
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 1,
            source: "init", updatedAt: Date()))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.81, opportunities: 5,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        let entry = try XCTUnwrap(try graph.recordedLemmas().first)
        XCTAssertEqual(entry.belief ?? 0, 0.81, accuracy: 0.0001)
    }

    func testRecordedLemmaBeliefIsNilWithoutBeliefRow() throws {
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 1,
            source: "init", updatedAt: Date()))

        let entry = try XCTUnwrap(try graph.recordedLemmas().first)
        XCTAssertNil(entry.belief)
    }
}
