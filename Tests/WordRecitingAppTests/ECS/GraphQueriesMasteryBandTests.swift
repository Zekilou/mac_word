import XCTest
@testable import WordRecitingApp

final class GraphQueriesMasteryBandTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries { world.graph }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func seed(lemmaId: String, band: Int, belief: Double?) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: lemmaId, band: band, freqRank: band * 1000, source: "test"))
        if let belief {
            try world.registry.upsertComponent(MasteryBeliefComponent(
                entityId: lemmaId, belief: belief, opportunities: 1,
                lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        }
    }

    func testMasteryByBandAggregatesObservedOnly() throws {
        try seed(lemmaId: "L1", band: 1, belief: 0.9)
        try seed(lemmaId: "L2", band: 1, belief: 0.7)
        try seed(lemmaId: "L3", band: 2, belief: nil)

        let stats = try graph.masteryByBand()
        let band1 = try XCTUnwrap(stats.first { $0.band == 1 })
        XCTAssertEqual(band1.observedCount, 2)
        XCTAssertEqual(band1.sumBelief, 1.6, accuracy: 0.0001)

        let band2 = try XCTUnwrap(stats.first { $0.band == 2 })
        XCTAssertEqual(band2.observedCount, 0)
    }

    func testMasteryDistributionUsesThresholds() throws {
        try seed(lemmaId: "L1", band: 1, belief: 0.95)
        try seed(lemmaId: "L2", band: 1, belief: 0.10)
        try seed(lemmaId: "L3", band: 1, belief: 0.50)

        let distribution = try graph.masteryDistribution(
            knownThreshold: WordMarkState.knownThreshold,
            unknownThreshold: WordMarkState.unknownThreshold)

        XCTAssertEqual(distribution.known, 1)
        XCTAssertEqual(distribution.unknown, 1)
        XCTAssertEqual(distribution.learning, 1)
        XCTAssertEqual(distribution.total, 3)
    }
}
