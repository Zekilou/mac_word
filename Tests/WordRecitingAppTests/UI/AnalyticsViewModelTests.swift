import XCTest
@testable import WordRecitingApp

@MainActor
final class AnalyticsViewModelTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func seed(lemmaId: String, band: Int, belief: Double) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: lemmaId, band: band, freqRank: band * 1000, source: "test"))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: lemmaId, belief: belief, opportunities: 1,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
    }

    func testDistributionAndProfileAreBuiltOnReload() throws {
        try seed(lemmaId: "L1", band: 1, belief: 0.9)
        try seed(lemmaId: "L2", band: 1, belief: 0.1)

        let vm = AnalyticsViewModel(world: world)
        vm.reload()

        XCTAssertEqual(vm.distribution?.known, 1)
        XCTAssertEqual(vm.distribution?.unknown, 1)
        let profile = try XCTUnwrap(vm.profile)
        let band1 = try XCTUnwrap(profile.bands.first { $0.band == 1 })
        XCTAssertEqual(band1.observedFamilies, 2)
        XCTAssertGreaterThan(profile.estimatedKnownTotal, 0)
    }

    func testEmptyStateDoesNotCrash() throws {
        let vm = AnalyticsViewModel(world: world)
        vm.reload()
        XCTAssertEqual(vm.distribution?.total ?? 0, 0)
        // 空库也会构建出画像：真实词频表已加载，未观测词按词频先验外推。
        XCTAssertNotNil(vm.profile)
    }
}
