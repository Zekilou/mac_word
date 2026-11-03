import XCTest
@testable import WordRecitingCore
@testable import WordRecitingUI

@MainActor
final class StudyViewModelTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var suiteName: String!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        // @ai: 用独立 suite，避免跑测试改写用户的真实调度算法设置。
        suiteName = "StudyViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// 造一张卡并挂到 lemma 上（含 text/frequency/belief + instantiates 边）。
    private func makeCard(_ cardId: String, lemmaId: String = "L1") throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        try world.registry.insertNode(id: cardId, kind: .card, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: lemmaId, textA: "abandon", textB: "放弃", language: nil))
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: lemmaId, band: 2, freqRank: 1001, source: "test"))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: lemmaId, belief: 0.44, opportunities: 2,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        try world.registry.insertEdge(
            id: "inst-\(cardId)", srcId: cardId, dstId: lemmaId,
            rel: .instantiates, createdAt: Date())
    }

    private func cardItem(_ cardId: String, lemmaId: String = "L1") -> CardListItem {
        CardListItem(
            cardId: cardId, lemmaId: lemmaId, text: "abandon", definition: "放弃",
            dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)
    }

    private func vm() -> StudyViewModel {
        StudyViewModel(world: world, settings: settings)
    }

    private func schedule(_ cardId: String) throws -> ScheduleStateComponent? {
        try world.registry.fetchComponents(for: cardId, table: "comp_schedule_state")
    }

    // MARK: - 纯函数

    func testSummaryTextLabelsAndOrder() {
        let text = StudyViewModel.summaryText(counts: ["seen": 3, "mark_unknown": 1])
        XCTAssertEqual(text, "标记不会 1 次 · 出现过 3 次")
    }

    func testSummaryTextIsNilWhenEmpty() {
        XCTAssertNil(StudyViewModel.summaryText(counts: [:]))
    }

    /// 「为什么这张卡现在出现」——审计 P2 的缺失项。
    func testProvenanceText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            StudyViewModel.provenanceText(reps: nil, dueAt: nil, now: now), "新卡 · 第一次学")
        XCTAssertEqual(
            StudyViewModel.provenanceText(reps: 0, dueAt: nil, now: now), "新卡 · 第一次学")
        XCTAssertEqual(
            StudyViewModel.provenanceText(
                reps: 2, dueAt: now.addingTimeInterval(-3 * 86_400), now: now),
            "复习 · 逾期 3 天")
        XCTAssertEqual(
            StudyViewModel.provenanceText(
                reps: 2, dueAt: now.addingTimeInterval(-2 * 3_600), now: now),
            "复习 · 逾期 2 小时")
        // 未到期（提前打开 / 时钟回拨）不能说成负的天数。
        XCTAssertEqual(
            StudyViewModel.provenanceText(
                reps: 2, dueAt: now.addingTimeInterval(86_400), now: now),
            "复习 · 未到期")
    }

    func testPhoneticText() {
        XCTAssertNil(StudyViewModel.phoneticText(us: nil, uk: nil))
        XCTAssertNil(StudyViewModel.phoneticText(us: "  ", uk: ""))
        XCTAssertEqual(StudyViewModel.phoneticText(us: "/əˈbændən/", uk: nil), "/əˈbændən/")
        XCTAssertEqual(StudyViewModel.phoneticText(us: nil, uk: "/əˈbændən/"), "/əˈbændən/")
        XCTAssertEqual(
            StudyViewModel.phoneticText(us: "/əˈbændən/", uk: "/əˈbændən/"), "/əˈbændən/",
            "美英一致时不重复展示")
        XCTAssertEqual(
            StudyViewModel.phoneticText(us: "/əˈbændən/", uk: "/əˈbændɒn/"),
            "美 /əˈbændən/ · 英 /əˈbændɒn/")
    }

    // MARK: - 画像

    func testRefreshCurrentProfileLoadsCardInfo() throws {
        try makeCard("C1")
        let vm = vm()
        vm.queue = [cardItem("C1")]

        vm.refreshCurrentProfile()

        XCTAssertEqual(vm.currentBelief ?? 0, 0.44, accuracy: 0.0001)
        XCTAssertEqual(vm.currentBand, 2)
        XCTAssertEqual(vm.currentRank, 1001)
        XCTAssertNil(vm.currentEventSummary)
        XCTAssertEqual(vm.currentProvenance, "新卡 · 第一次学")
    }

    func testRefreshCurrentProfileClearsWithoutCard() throws {
        let vm = vm()
        vm.queue = []
        vm.refreshCurrentProfile()
        XCTAssertNil(vm.currentBelief)
        XCTAssertNil(vm.currentBand)
        XCTAssertNil(vm.currentProvenance)
    }

    func testRefreshCurrentProfileLoadsPhonetic() throws {
        try makeCard("C1")
        try world.registry.upsertComponent(LemmaMetaComponent(
            entityId: "L1", pos: "v.", phoneticUs: "/əˈbændən/",
            phoneticUk: nil, sensesJson: nil))
        let vm = vm()
        vm.queue = [cardItem("C1")]
        vm.refreshCurrentProfile()
        XCTAssertEqual(vm.currentPhonetic, "/əˈbændən/")
    }

    // MARK: - 评分前置条件（误触跳卡）

    /// 背面才能评分：正面按 1–4 必须无效（旧实现会直接跳卡）。
    func testRateRequiresBackSide() throws {
        try makeCard("C1")
        let vm = vm()
        vm.queue = [cardItem("C1")]

        XCTAssertTrue(vm.isFront)
        XCTAssertFalse(vm.canRate)
        vm.rate(.good)
        XCTAssertEqual(vm.remaining, 1, "正面评分不能推进队列")
        XCTAssertNil(try schedule("C1"), "正面评分不能写库")

        vm.flip()
        XCTAssertTrue(vm.canRate)
        vm.rate(.good)
        XCTAssertEqual(vm.remaining, 0)
        XCTAssertNotNil(try schedule("C1"))
    }

    /// 评分后同一张卡不能重复评分（防连点把中间的卡吃掉）。
    func testRatingIsLockedForTheRatedCard() throws {
        try makeCard("C1")
        try makeCard("C2", lemmaId: "L2")
        let vm = vm()
        vm.queue = [cardItem("C1"), cardItem("C2")]
        vm.flip()

        vm.rate(.good)
        XCTAssertFalse(vm.hasRatedCurrent, "换到下一张后不应仍处于「已评」状态")
        XCTAssertEqual(vm.currentCard?.cardId, "C2")
        // @ai: 换卡后会回到正面（新的一张必须重新翻开才能评分）。
        XCTAssertTrue(vm.isFront)
        XCTAssertFalse(vm.canRate, "新卡回到正面，需重新翻开")

        vm.flip()
        XCTAssertTrue(vm.canRate)
    }

    // MARK: - 进度保持（刷新丢进度）

    func testReloadKeepsProgressAndHidesRatedCards() throws {
        try makeCard("C1")
        try makeCard("C2", lemmaId: "L2")
        let vm = vm()
        vm.reload()
        XCTAssertEqual(vm.queue.count, 2)

        vm.flip()
        vm.rate(.good)
        XCTAssertEqual(vm.remaining, 1)

        // 「刷新」不能把已经评过的卡再端回来。
        vm.reload()
        XCTAssertEqual(vm.completedInRound, 0, "刷新后游标归零，但已评卡不再入队")
        XCTAssertFalse(vm.queue.contains { $0.cardId == "C1" })
        XCTAssertEqual(vm.queue.count, 1)
    }

    func testSkipAdvancesWithoutWritingSchedule() throws {
        try makeCard("C1")
        try makeCard("C2", lemmaId: "L2")
        let vm = vm()
        vm.queue = [cardItem("C1"), cardItem("C2")]

        vm.skip()
        XCTAssertEqual(vm.currentCard?.cardId, "C2")
        XCTAssertNil(try schedule("C1"), "跳过不得写调度状态")
        XCTAssertTrue(vm.isFront)
    }

    func testUndoReturnsToPreviousCard() throws {
        try makeCard("C1")
        try makeCard("C2", lemmaId: "L2")
        let vm = vm()
        vm.queue = [cardItem("C1"), cardItem("C2")]
        vm.flip()
        vm.rate(.good)

        vm.undoLastRating()

        XCTAssertEqual(vm.currentCard?.cardId, "C1")
        XCTAssertFalse(vm.isFront, "撤销后停在用户刚看的释义面")
        XCTAssertFalse(vm.hasRatedCurrent)
        XCTAssertTrue(vm.canRate)
    }

    // MARK: - 调度算法生效

    /// 设置里选「SM-2 + 词频」，评分必须真的走那条策略。
    /// @ai: 旧实现 `StudyOp.policyID` 恒为默认 `.sm2`，设置页的选项是死的。
    func testRateHonorsSchedulerFromSettings() throws {
        settings.schedulerID = .sm2Frequency
        try makeCard("C1")
        let vm = vm()
        vm.queue = [cardItem("C1")]
        vm.flip()
        vm.rate(.good)

        let state = try XCTUnwrap(schedule("C1"))
        XCTAssertEqual(state.schedulerId, SchedulerID.sm2Frequency.rawValue)
    }

    func testRateUsesSM2WhenSettingsSaySo() throws {
        settings.schedulerID = .sm2
        try makeCard("C1")
        let vm = vm()
        vm.queue = [cardItem("C1")]
        vm.flip()
        vm.rate(.good)

        XCTAssertEqual(
            try XCTUnwrap(schedule("C1")).schedulerId, SchedulerID.sm2.rawValue)
    }

    // MARK: - 空状态原因

    func testEmptyReasonWithoutCards() throws {
        let vm = vm()
        vm.reload()
        XCTAssertEqual(vm.emptyReason, .noCards)
    }

    func testEmptyReasonWhenTodayCleared() throws {
        try makeCard("C1")
        let vm = vm()
        vm.reload()
        vm.flip()
        vm.rate(.good)
        // 评完最后一张：队列空，且库里没有新的到期卡。
        XCTAssertFalse(vm.hasCards)
        XCTAssertEqual(vm.emptyReason, .clearedToday)
    }
}
