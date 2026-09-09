import XCTest
import GRDB
@testable import WordRecitingApp

@MainActor
final class VocabularyListViewModelTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var vm: VocabularyListViewModel!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        vm = VocabularyListViewModel(world: world)
    }

    private func makeLemma(_ id: String, _ text: String, definition: String? = nil) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: definition, language: nil))
    }

    func testReloadLoadsRecordedLemmas() throws {
        try makeLemma("L1", "abandon", definition: "放弃")
        try makeLemma("L2", "battle")
        try world.run(UserKnownSystem(), context: .batch(
            words: [("abandon", false), ("battle", true)], source: "init"))

        vm.reload()
        XCTAssertEqual(vm.entries.count, 2)
        XCTAssertEqual(vm.countByState.known, 1)
        XCTAssertEqual(vm.countByState.unknown, 1)
        XCTAssertEqual(vm.countByState.seen, 0)
    }

    func testFilterByState() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "battle")
        try makeLemma("L3", "cold")
        try world.run(UserKnownSystem(), context: .batch(
            words: [("abandon", false), ("battle", true)], source: "init"))
        try world.run(UserKnownSystem(), context: .markSeen(words: ["cold"], source: "rss"))
        vm.reload()

        vm.filter = .known
        XCTAssertEqual(vm.filtered.map(\.text), ["battle"])
        vm.filter = .unknown
        XCTAssertEqual(vm.filtered.map(\.text), ["abandon"])
        vm.filter = .seen
        XCTAssertEqual(vm.filtered.map(\.text), ["cold"])
        vm.filter = .all
        XCTAssertEqual(vm.filtered.count, 3)
    }

    func testSearchText() throws {
        try makeLemma("L1", "abandon", definition: "放弃")
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: "L1", source: "init"))
        vm.reload()

        vm.searchText = "aban"
        XCTAssertEqual(vm.filtered.count, 1)
        vm.searchText = "放弃"
        XCTAssertEqual(vm.filtered.count, 1)
        vm.searchText = "zzz"
        XCTAssertTrue(vm.filtered.isEmpty)
    }

    func testDisplayTextStripsPhoneticTail() throws {
        try makeLemma("L1", "abandon[ə'bændən]", definition: "放弃")
        try world.run(UserKnownSystem(), context: .markKnown(lemmaId: "L1", source: "init"))
        vm.reload()

        XCTAssertEqual(vm.displayText(try XCTUnwrap(vm.entries.first)), "abandon")
    }

    func testSortByReadingFrequency() throws {
        try makeLemma("L1", "alpha")
        try makeLemma("L2", "beta")
        try makeLemma("L3", "gamma")
        try world.run(UserKnownSystem(), context: .batch(
            words: [("alpha", true), ("beta", true), ("gamma", true)], source: "init"))
        // 阅读频次：alpha=2、beta=1、gamma=1
        try world.run(UserKnownSystem(), context: .markSeen(words: ["beta"], source: "rss"))
        try world.run(UserKnownSystem(), context: .markSeen(
            words: ["alpha", "alpha", "gamma"], source: "rss"))
        vm.reload()

        vm.sortOrder = .frequent
        XCTAssertEqual(vm.filtered.first?.text, "alpha", "阅读频次最高排前")
        XCTAssertEqual(vm.filtered.first?.seenCount, 2)
        vm.sortOrder = .rare
        XCTAssertEqual(vm.filtered.first?.seenCount, 1, "频次最低排前")
        vm.sortOrder = .recent
        XCTAssertEqual(vm.filtered.count, 3)
    }

    func testBeliefTextFormatting() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 1,
            source: "init", updatedAt: Date()))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.847, opportunities: 5,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)
        XCTAssertEqual(vm.beliefText(entry), "85%")
    }

    func testBeliefTextIsNilWithoutBelief() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 1,
            source: "init", updatedAt: Date()))

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)
        XCTAssertNil(vm.beliefText(entry))
    }

    // MARK: - 概率主口径改造

    private func seedEntry(lemmaId: String, text: String, mastery: Double?,
                           belief: Double?, seenCount: Int = 1) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: lemmaId, textA: text, textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: lemmaId, mastery: mastery ?? 0, seenCount: seenCount,
            source: "init", updatedAt: Date()))
        if let belief {
            try world.registry.upsertComponent(MasteryBeliefComponent(
                entityId: lemmaId, belief: belief, opportunities: 3,
                lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        }
    }

    /// 用户标了「会」，但模型概率低 → 判定以概率为准。
    func testStateIsDrivenByBeliefNotMastery() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: 0.12)

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)

        XCTAssertEqual(vm.markState(entry), .unknown)
    }

    func testStateFallsBackToMasteryWithoutBelief() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: nil)

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)

        XCTAssertEqual(vm.markState(entry), .known)
    }

    func testContextAndEventCountsAreLoaded() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: 0.8)
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .lookup, trust: 1.0, detail: nil))
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .rss(articleId: "A1", title: nil),
            kind: .seen, trust: 0.0, detail: nil))

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)

        XCTAssertEqual(entry.contextCount, 2)
        XCTAssertEqual(entry.eventCount, 2)
    }

    func testSortByMasteryDescending() throws {
        try seedEntry(lemmaId: "L1", text: "low", mastery: 2.0, belief: 0.2)
        try seedEntry(lemmaId: "L2", text: "high", mastery: 2.0, belief: 0.9)
        try seedEntry(lemmaId: "L3", text: "none", mastery: 2.0, belief: nil)

        let vm = VocabularyListViewModel(world: world)
        vm.sortOrder = .mastery

        XCTAssertEqual(vm.filtered.map(\.lemmaID), ["L2", "L1", "L3"])
    }

    func testBeliefTextUsesPercentPresentation() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: 0.847)

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)

        XCTAssertEqual(vm.beliefText(entry), "85%")
    }
}
