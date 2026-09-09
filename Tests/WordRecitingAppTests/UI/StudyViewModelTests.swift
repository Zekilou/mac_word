import XCTest
@testable import WordRecitingApp

@MainActor
final class StudyViewModelTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeCard(_ cardId: String) throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.insertNode(id: cardId, kind: .card, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: "放弃", language: nil))
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "test"))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.44, opportunities: 2,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
    }

    private func cardItem(_ cardId: String) -> CardListItem {
        CardListItem(cardId: cardId, lemmaId: "L1", text: "abandon", definition: "放弃",
                     dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)
    }

    func testSummaryTextLabelsAndOrder() {
        let text = StudyViewModel.summaryText(counts: ["seen": 3, "mark_unknown": 1])
        XCTAssertEqual(text, "标记不会 1 次 · 出现过 3 次")
    }

    func testSummaryTextIsNilWhenEmpty() {
        XCTAssertNil(StudyViewModel.summaryText(counts: [:]))
    }

    func testRefreshCurrentProfileLoadsCardInfo() throws {
        try makeCard("C1")
        let vm = StudyViewModel(world: world)
        vm.queue = [cardItem("C1")]

        vm.refreshCurrentProfile()

        XCTAssertEqual(vm.currentBelief ?? 0, 0.44, accuracy: 0.0001)
        XCTAssertEqual(vm.currentBand, 2)
        XCTAssertEqual(vm.currentRank, 1001)
        XCTAssertNil(vm.currentEventSummary)
    }

    func testRefreshCurrentProfileClearsWithoutCard() throws {
        let vm = StudyViewModel(world: world)
        vm.queue = []
        vm.refreshCurrentProfile()
        XCTAssertNil(vm.currentBelief)
        XCTAssertNil(vm.currentBand)
    }

    func testRateAdvancesAndReloadsProfile() throws {
        try makeCard("C1")
        try world.registry.insertNode(id: "C2", kind: .card, createdAt: Date())
        let vm = StudyViewModel(world: world)
        vm.queue = [cardItem("C1"), cardItem("C2")]
        vm.refreshCurrentProfile()

        vm.rate(.good)

        XCTAssertEqual(vm.currentEventSummary, "答对 1 次")
        // 答对会触发 BKT 重放并抬高后验，故只断言「比初始值高」而非固定值。
        XCTAssertGreaterThan(vm.currentBelief ?? 0, 0.44)
    }
}
