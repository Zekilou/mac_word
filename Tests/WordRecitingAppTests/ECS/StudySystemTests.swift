import XCTest
import GRDB
@testable import WordRecitingApp

/// 背诵复习闭环测试：StudySystem（SM-2 调度）+ 复习查询（dueCards/studyStats/cardForLemma/weakLemmaDetails）。
/// @ai: 写入走 World.run(StudySystem)；查询走 GraphQueries 命名方法。
final class StudySystemTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry!
    private var graph: GraphQueries!

    /// 基准时间（用固定值保证确定性）。
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        registry = world.registry
        graph = world.graph
    }

    /// 造一个小词库：3 个 lemma + 3 张卡（card-1 已学且到期；card-2/3 未排程=新卡）。
    private func seedDeck() throws {
        for (id, text) in [("lemma-1", "abandon"), ("lemma-2", "battle"), ("lemma-3", "happy")] {
            try registry.insertNode(id: id, kind: .lemma, createdAt: now)
            try registry.upsertComponent(TextComponent(
                entityId: id, textA: text, textB: "def-\(text)", language: "en"))
        }
        for id in ["card-1", "card-2", "card-3"] {
            try registry.insertNode(id: id, kind: .card, createdAt: now)
        }
        try registry.insertNode(id: "deck-1", kind: .deck, createdAt: now)
        for (i, cardId) in ["card-1", "card-2", "card-3"].enumerated() {
            try registry.insertEdge(
                id: "has-\(cardId)", srcId: "deck-1", dstId: cardId, rel: .has, createdAt: now)
            try registry.insertEdge(
                id: "inst-\(cardId)", srcId: cardId, dstId: "lemma-\(i + 1)", rel: .instantiates, createdAt: now)
        }
        try registry.upsertComponent(DeckMetaComponent(
            entityId: "deck-1", name: "TestDeck", sourceKind: "csv",
            sourcePath: nil, importedAt: now))
        // card-1：已学 1 次、到期（dueAt 早于 now）
        try registry.upsertComponent(ScheduleStateComponent(
            entityId: "card-1", stability: 3, difficulty: 2.5, dueAt: now,
            intervalDays: 3, reps: 1, lapses: 0, lastRating: 3,
            lastReviewedAt: now, schedulerId: "sm-2", queue: "review", customDataJson: nil))
    }

    private func state(_ cardId: EntityID) throws -> ScheduleStateComponent? {
        try registry.fetchComponents(for: cardId, table: "comp_schedule_state")
    }

    // MARK: - StudySystem：首次评分

    func testFirstAgainSchedulesTenMinutes() throws {
        try seedDeck()
        try world.run(StudySystem(), context: .init(cardId: "card-2", rating: .again, reviewedAt: now))
        let s = try XCTUnwrap(state("card-2"))
        XCTAssertEqual(s.reps, 1)
        XCTAssertEqual(s.queue, "learning")
        let expected = now.addingTimeInterval(10.0 / 1440.0 * 86400)
        XCTAssertEqual(s.dueAt!.timeIntervalSince(expected), 0, accuracy: 1)
    }

    func testFirstGoodSchedulesThreeDays() throws {
        try seedDeck()
        try world.run(StudySystem(), context: .init(cardId: "card-2", rating: .good, reviewedAt: now))
        let s = try XCTUnwrap(state("card-2"))
        XCTAssertEqual(s.reps, 1)
        XCTAssertEqual(s.queue, "review")
        XCTAssertEqual(s.intervalDays, 3)
        XCTAssertEqual(s.dueAt!.timeIntervalSince(now.addingTimeInterval(3 * 86400)), 0, accuracy: 1)
    }

    func testFirstEasySchedulesSevenDays() throws {
        try seedDeck()
        try world.run(StudySystem(), context: .init(cardId: "card-2", rating: .easy, reviewedAt: now))
        XCTAssertEqual(try state("card-2")?.intervalDays, 7)
    }

    // MARK: - StudySystem：后续评分

    func testSubsequentGoodMultipliesInterval() throws {
        try seedDeck()
        // card-1：reps=1, interval=3, factor=2.5 → good → 3×2.5=7.5
        try world.run(StudySystem(), context: .init(cardId: "card-1", rating: .good, reviewedAt: now))
        let s = try XCTUnwrap(state("card-1"))
        XCTAssertEqual(s.reps, 2)
        XCTAssertEqual(s.intervalDays ?? 0, 7.5, accuracy: 0.001)
        XCTAssertEqual(s.difficulty ?? 0, 2.5, accuracy: 0.001)
    }

    func testAgainResetsIntervalAndIncrementsLapses() throws {
        try seedDeck()
        // 先把 card-1 推到 reps=3, interval=10, lapses=1
        try registry.upsertComponent(ScheduleStateComponent(
            entityId: "card-1", stability: 10, difficulty: 2.5, dueAt: now,
            intervalDays: 10, reps: 3, lapses: 1, lastRating: 3,
            lastReviewedAt: now, schedulerId: "sm-2", queue: "review", customDataJson: nil))
        try world.run(StudySystem(), context: .init(cardId: "card-1", rating: .again, reviewedAt: now))
        let s = try XCTUnwrap(state("card-1"))
        XCTAssertEqual(s.reps, 4)
        XCTAssertEqual(s.lapses, 2)
        XCTAssertEqual(s.intervalDays, 1)
        XCTAssertEqual(s.difficulty ?? 0, 2.3, accuracy: 0.001)  // 2.5 - 0.2
    }

    // MARK: - 落库：review_event + produces 边

    func testReviewEventAndProducesEdgeCreated() throws {
        try seedDeck()
        try world.run(StudySystem(), context: .init(cardId: "card-2", rating: .hard, reviewedAt: now))

        let events = try appDB.dbWriter.read { db in
            try ReviewEventComponent.fetchAll(db)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].rating, 2)
        XCTAssertEqual(events[0].targetCardId, "card-2")

        let edges = try appDB.dbWriter.read { db in
            try EdgeRecord.fetchAll(
                db, sql: "SELECT * FROM edges WHERE src_id = ? AND rel_type = 'produces'",
                arguments: ["card-2"])
        }
        XCTAssertEqual(edges.count, 1)
        let eventId = edges[0].dstId
        let kind: String? = try appDB.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT kind FROM nodes WHERE id = ?", arguments: [eventId])
        }
        XCTAssertEqual(kind, "event")
    }

    // MARK: - 查询：dueCards

    func testDueCardsIncludesNewAndDueExcludesFuture() throws {
        try seedDeck()
        // card-3 未来到期 → 不进队列
        try registry.upsertComponent(ScheduleStateComponent(
            entityId: "card-3", stability: nil, difficulty: nil,
            dueAt: now.addingTimeInterval(10 * 86400), intervalDays: 10, reps: 1, lapses: 0,
            lastRating: 3, lastReviewedAt: now, schedulerId: "sm-2", queue: "review", customDataJson: nil))

        let due = try graph.dueCards(limit: 10, now: now)
        let ids = Set(due.map(\.cardId))
        XCTAssertEqual(ids, ["card-1", "card-2"])
        XCTAssertFalse(ids.contains("card-3"))
        // 新卡（card-2，无 due_at）排最前
        XCTAssertEqual(due.first?.cardId, "card-2")
    }

    func testDueCardsCarriesLemmaAndDefinition() throws {
        try seedDeck()
        let due = try graph.dueCards(limit: 10, now: now)
        let card1 = try XCTUnwrap(due.first { $0.cardId == "card-1" })
        XCTAssertEqual(card1.lemmaId, "lemma-1")
        XCTAssertEqual(card1.plainText, "abandon")
        XCTAssertEqual(card1.definition, "def-abandon")
        XCTAssertEqual(card1.reps, 1)
    }

    // MARK: - 查询：studyStats

    func testStudyStatsAggregates() throws {
        try seedDeck()
        // 再对 card-2 评一次 .again（当天）
        try world.run(StudySystem(), context: .init(cardId: "card-2", rating: .again, reviewedAt: Date()))
        let s = try graph.studyStats(now: Date())
        XCTAssertEqual(s.totalCards, 3)
        XCTAssertEqual(s.studiedCards, 2)          // card-1 + card-2 都有 reps>0
        XCTAssertEqual(s.dueCount, 2)              // card-1 已过期 + card-3 未排程；card-2 已延期
        XCTAssertEqual(s.reviewedToday, 1)
        XCTAssertEqual(s.totalReviews, 1)
        XCTAssertEqual(s.againRatio, 1.0)
    }

    // MARK: - 查询：cardForLemma

    func testCardForLemmaFindsCard() throws {
        try seedDeck()
        let card = try graph.cardForLemma("lemma-1")
        XCTAssertEqual(card?.cardId, "card-1")
        XCTAssertEqual(card?.plainText, "abandon")
        XCTAssertNil(try graph.cardForLemma("lemma-999"))
    }

    // MARK: - 查询：weakLemmaDetails

    func testWeakLemmaDetailsRanksByAgainRatio() throws {
        try seedDeck()
        try world.run(StudySystem(), context: .init(cardId: "card-1", rating: .again, reviewedAt: now))
        try world.run(StudySystem(), context: .init(cardId: "card-2", rating: .good, reviewedAt: now))

        let weak = try graph.weakLemmaDetails(limit: 10)
        XCTAssertEqual(weak.count, 2)
        XCTAssertEqual(weak.first?.text, "abandon")   // AGAIN 比例 1.0 排第一
        XCTAssertEqual(weak.first?.againCount, 1)
        XCTAssertEqual(weak.last?.text, "battle")     // 0.0
        XCTAssertEqual(weak.last?.againRatio, 0.0)
    }

    // MARK: - ViewModel 联动（@MainActor）

    @MainActor func testStudyViewModelLoadsDueQueueAndRates() throws {
        try seedDeck()
        let vm = StudyViewModel(world: world)
        vm.reload()
        XCTAssertFalse(vm.queue.isEmpty)
        XCTAssertEqual(vm.queue.first?.cardId, "card-2")   // 新卡优先
        let before = vm.stats?.totalReviews ?? 0
        vm.rate(.good)
        XCTAssertEqual(vm.remaining, vm.queue.count - 1)
        XCTAssertEqual((vm.stats?.totalReviews ?? 0), before + 1)
    }

    @MainActor func testGenerateViewModelReadingMarkDrivesSchedule() throws {
        try seedDeck()
        let vm = GenerateViewModel(world: world)
        XCTAssertEqual(vm.cardForReading("lemma-1")?.cardId, "card-1")
        XCTAssertTrue(vm.markReadingWord(lemmaId: "lemma-1", rating: .good))
        XCTAssertTrue(vm.ratedLemmaIds.contains("lemma-1"))
        let s: ScheduleStateComponent? = try registry.fetchComponents(
            for: "card-1", table: "comp_schedule_state")
        XCTAssertEqual(s?.reps, 2)   // seed 1 次 + 阅读标记 1 次
        XCTAssertFalse(vm.markReadingWord(lemmaId: "lemma-999", rating: .good))
    }
}
