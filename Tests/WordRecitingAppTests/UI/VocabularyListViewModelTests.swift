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
}
