import XCTest
import GRDB
@testable import WordRecitingApp

@MainActor
final class RegionWiringTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    // MARK: - 主动：复习做题

    func testStudyRateRecordsQuizEvent() throws {
        try makeLemma("L1", "abandon")
        try world.registry.insertNode(id: "C1", kind: .card, createdAt: Date())

        let vm = StudyViewModel(world: world)
        vm.queue = [CardListItem(
            cardId: "C1", lemmaId: "L1", text: "abandon", definition: nil,
            dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)]
        vm.rate(.good)

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'quiz_correct'"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_region WHERE kind = 'study'"), 1)
    }

    func testStudyAgainRecordsQuizWrong() throws {
        try makeLemma("L1", "abandon")
        try world.registry.insertNode(id: "C1", kind: .card, createdAt: Date())

        let vm = StudyViewModel(world: world)
        vm.queue = [CardListItem(
            cardId: "C1", lemmaId: "L1", text: "abandon", definition: nil,
            dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)]
        vm.rate(.again)

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'quiz_wrong'"), 1)
    }

    // MARK: - 主动：词典查词标记

    func testDictionaryToggleMarkRecordsEvent() throws {
        try makeLemma("L1", "abandon")
        let vm = SystemDictionaryViewModel(world: world)
        vm.toggleMark("abandon")

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'mark_known' AND trust = 1"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_region WHERE kind = 'dictionary'"), 1)
    }

    // MARK: - 被动 + 主动：RSS

    func testRSSPassiveSeenHasZeroTrust() throws {
        try makeLemma("L1", "abandon")
        let defaults = UserDefaults(suiteName: "test-region-\(UUID())")!
        let vm = RSSViewModel(world: world, store: RSSSourceStore(defaults: defaults))
        vm.selectedItem = RSSItem(id: "A1", title: "文章", link: "", summary: "",
                                  content: "", pubDate: nil)
        vm.presentArticle(text: "We abandon the old plan.")

        // 正文里每个词都会被 markSeen 建 Lemma，被动 seen 事件数与提取词数一致且 trust = 0。
        XCTAssertGreaterThan(vm.words.count, 0)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'seen' AND trust = 0"),
            vm.words.count)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_region WHERE kind = 'rss'"), 1)
    }

    func testRSSToggleRecordsHighTrustEvent() throws {
        try makeLemma("L1", "abandon")
        let defaults = UserDefaults(suiteName: "test-region-\(UUID())")!
        let vm = RSSViewModel(world: world, store: RSSSourceStore(defaults: defaults))
        vm.selectedItem = RSSItem(id: "A1", title: "文章", link: "", summary: "",
                                  content: "", pubDate: nil)
        vm.toggle(InitWord(surface: "abandon", lemma: "abandon"))

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE trust = 1 AND event_kind = 'mark_unknown'"), 1)
    }

    // MARK: - 主动：词汇初始化

    func testInitSubmitRecordsBatchEvents() throws {
        try makeLemma("L1", "abandon")
        let vm = VocabularyInitViewModel(world: world)
        vm.words = [InitWord(surface: "abandon", lemma: "abandon")]
        vm.sessionStates = ["abandon": false]
        vm.stage = .ready
        vm.submit()

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'mark_unknown' AND trust = 1"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_region WHERE kind = 'init'"), 1)
    }
}
