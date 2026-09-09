import XCTest
@testable import WordRecitingApp

final class GraphQueriesFeaturesTests: XCTestCase {
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

    func testFeaturesCombineBeliefFrequencyEventsAndCard() throws {
        let now = Date()
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.62, opportunities: 3,
            lastEventAt: now, updatedAt: now, paramsVersion: "bkt-1"))
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "test"))
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .lookup, trust: 1.0, detail: nil))
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .rss(articleId: "A1", title: nil),
            kind: .seen, trust: 0.0, detail: nil))

        try world.registry.insertNode(id: "C1", kind: .card, createdAt: now)
        try world.registry.insertEdge(id: "edge-C1", srcId: "C1", dstId: "L1",
                                      rel: .instantiates, createdAt: now)
        try world.registry.upsertComponent(ScheduleStateComponent(
            entityId: "C1", stability: 3, difficulty: 2.5,
            dueAt: now.addingTimeInterval(86400), intervalDays: 3,
            reps: 2, lapses: 0, lastRating: 3, lastReviewedAt: now,
            schedulerId: "sm-2", queue: "review", customDataJson: nil))

        let features = try XCTUnwrap(try graph.wordFeatures(lemmaIds: ["L1"])["L1"])

        XCTAssertEqual(features.lemmaId, "L1")
        XCTAssertEqual(features.belief ?? 0, 0.62, accuracy: 0.0001)
        XCTAssertEqual(features.band, 2)
        XCTAssertEqual(features.rank, 1001)
        XCTAssertEqual(features.eventCount, 2)
        XCTAssertEqual(features.contextCount, 2)
        XCTAssertNotNil(features.lastEventAt)
        XCTAssertEqual(features.card?.cardId, "C1")
        XCTAssertEqual(features.card?.reps, 2)
        XCTAssertEqual(features.card?.intervalDays ?? 0, 3, accuracy: 0.0001)
    }

    func testFeaturesWithoutCardAndWithoutData() throws {
        try makeLemma("L2", "ability")

        let features = try XCTUnwrap(try graph.wordFeatures(lemmaIds: ["L2"])["L2"])

        XCTAssertNil(features.belief)
        XCTAssertNil(features.band)
        XCTAssertNil(features.card)
        XCTAssertEqual(features.eventCount, 0)
        XCTAssertEqual(features.contextCount, 0)
    }

    func testBatchLookupReturnsOnlyRequestedLemmas() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "ability")
        try makeLemma("L3", "zebra")

        let result = try graph.wordFeatures(lemmaIds: ["L1", "L3"])

        XCTAssertEqual(Set(result.keys), ["L1", "L3"])
    }

    func testEmptyIdsReturnsEmpty() throws {
        XCTAssertTrue(try graph.wordFeatures(lemmaIds: []).isEmpty)
    }

    func testDbVersionWorksInsideWriteTransaction() throws {
        try makeLemma("L1", "abandon")

        try appDB.dbWriter.write { db in
            let result = try self.graph.wordFeatures(db, lemmaIds: ["L1"])
            XCTAssertNotNil(result["L1"])
        }
    }

    func testAllWordFeaturesCoversEveryLemma() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "ability")

        XCTAssertEqual(try graph.allWordFeatures().count, 2)
    }
}
