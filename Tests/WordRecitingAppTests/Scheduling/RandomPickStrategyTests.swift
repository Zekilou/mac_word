import XCTest
@testable import WordRecitingApp

@MainActor
final class RandomPickStrategyTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        suiteName = "RandomPick-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeVM() -> GenerateViewModel {
        GenerateViewModel(world: world, settings: AppSettings(defaults: defaults))
    }

    private func seedFeature(lemmaId: String, belief: Double?, band: Int? = nil) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        if let belief {
            try world.registry.upsertComponent(MasteryBeliefComponent(
                entityId: lemmaId, belief: belief, opportunities: 1,
                lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        }
        if let band {
            try world.registry.upsertComponent(LemmaFrequencyComponent(
                entityId: lemmaId, band: band, freqRank: band * 1000, source: "test"))
        }
    }

    private func cardItem(_ cardId: String, _ lemmaId: String, _ text: String) -> CardListItem {
        CardListItem(cardId: cardId, lemmaId: lemmaId, text: text, definition: nil,
                     dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)
    }

    func testCriticalWordsPrefersEdgeOfKnowing() throws {
        try seedFeature(lemmaId: "L-edge", belief: 0.5)
        try seedFeature(lemmaId: "L-known", belief: 0.95)
        try seedFeature(lemmaId: "L-unknown", belief: 0.05)

        let vm = makeVM()
        vm.selectedDeckId = "deck-1"
        vm.deckCards = [
            cardItem("C1", "L-edge", "edge"),
            cardItem("C2", "L-known", "known"),
            cardItem("C3", "L-unknown", "unknown")
        ]
        vm.randomCount = 1
        vm.wordScoringID = .criticalWords

        XCTAssertEqual(vm.randomPick(), ["L-edge"])
    }

    func testFrequencyTierPrefersHighFrequency() throws {
        try seedFeature(lemmaId: "L-1k", belief: nil, band: 1)
        try seedFeature(lemmaId: "L-25k", belief: nil, band: 25)

        let vm = makeVM()
        vm.selectedDeckId = "deck-1"
        vm.deckCards = [cardItem("C1", "L-1k", "the"), cardItem("C2", "L-25k", "zebra")]
        vm.randomCount = 1
        vm.wordScoringID = .frequencyTier

        XCTAssertEqual(vm.randomPick(), ["L-1k"])
    }

    func testWordFilterStaysAsPreFilter() throws {
        try seedFeature(lemmaId: "L-edge", belief: 0.5)

        let vm = makeVM()
        vm.selectedDeckId = "deck-1"
        vm.deckCards = [cardItem("C1", "L-edge", "edge")]
        vm.randomCount = 5
        vm.wordFilter = .learned
        vm.wordScoringID = .criticalWords

        XCTAssertTrue(vm.randomPick().isEmpty)
    }

    func testScoringIDRoundTripsThroughSettings() {
        let vm = makeVM()
        vm.wordScoringID = .criticalWords
        vm.persistSettings()

        XCTAssertEqual(AppSettings(defaults: defaults).wordScoringID, .criticalWords)
    }

    func testDefaultScoringIsRandom() {
        XCTAssertEqual(makeVM().wordScoringID, .random)
    }
}
