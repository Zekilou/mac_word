import XCTest
import GRDB
@testable import WordRecitingApp

@MainActor
final class VocabularyInitViewModelTests: XCTestCase {

    /// 108 词合格长段落（12 × 9 词句）——新合格线（≥100 词）下"合格"的 mock 输出。
    private let longPara = String(
        repeating: "The quiet farmer walks through the green valley every morning. ", count: 12)

    private struct MockClient: LLMClient {
        static let identifier = "mock"
        let response: String
        var onPrompt: @Sendable (String) -> Void = { _ in }
        func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
            onPrompt(prompt)
            return response
        }
    }

    /// 支持响应序列的 mock（重试测试用）：按调用次数依次返回，并记录 prompts。
    private struct SequenceMockClient: LLMClient {
        static let identifier = "mock"
        let responses: [String]
        private let box = SeqBox()
        var calls: Int { get async { await box.count } }
        var prompts: [String] { get async { await box.prompts } }
        func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
            let i = await box.record(prompt)
            return responses[min(i, responses.count - 1)]
        }
    }

    private actor SeqBox {
        private(set) var prompts: [String] = []
        private(set) var count = 0
        func record(_ p: String) -> Int {
            prompts.append(p)
            count += 1
            return count - 1
        }
    }

    private var appDB: AppDatabase!
    private var world: World!
    private var settings: AppSettings!
    private var vm: VocabularyInitViewModel!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        settings = AppSettings(defaults: UserDefaults(
            suiteName: "test-vocab-init-\(UUID().uuidString)")!)
        vm = VocabularyInitViewModel(world: world, settings: settings)
        vm.clientOverride = MockClient(response: "I get up early and make some tea. I go to work.")
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    /// 轮询等待 stage 到达目标（生成在全局中心托管执行，异步完成）。
    private func waitForStage(
        _ vm: VocabularyInitViewModel, _ target: VocabularyInitViewModel.Stage
    ) async {
        for _ in 0..<100 where vm.stage != target {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testGenerateFillsParagraphAndReachesReady() async throws {
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        XCTAssertEqual(vm.stage, .ready)
        XCTAssertEqual(vm.paragraph, "I get up early and make some tea. I go to work.")
        XCTAssertFalse(vm.words.isEmpty)
        XCTAssertTrue(vm.words.contains { $0.lemma == "tea" })
    }

    func testToggleCyclePendingToRedToPending() async throws {
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        let tea = vm.words.first { $0.lemma == "tea" }!
        // 无记录 → 灰；点击 → 红；再点击 → 回灰
        XCTAssertEqual(vm.markState(for: tea), .pending)
        vm.toggle(tea)
        XCTAssertEqual(vm.markState(for: tea), .unknown)
        XCTAssertEqual(vm.unknownCount, 1)
        vm.toggle(tea)
        XCTAssertEqual(vm.markState(for: tea), .pending)
        XCTAssertEqual(vm.unknownCount, 0)
    }

    func testSubmitWritesGlobalStateWithoutCards() async throws {
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        let tea = vm.words.first { $0.lemma == "tea" }!
        vm.toggle(tea)
        vm.submit()

        XCTAssertEqual(vm.stage, .done)
        XCTAssertEqual(vm.submittedCount, vm.words.count)
        // 每个词写入 comp_user_known（不含重复）
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_user_known"), vm.words.count)
        // tea 标不会（mastery 1），其余会（mastery 2）
        let teaLemma = try XCTUnwrap(graphLemma("tea"))
        XCTAssertEqual(try graphMastery(teaLemma), 1.0)
        let workLemma = try XCTUnwrap(graphLemma("work"))
        XCTAssertEqual(try graphMastery(workLemma), 2.0)
        // 状态与卡片彻底分离：不建卡
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'card'"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_schedule_state"), 0)
    }

    func testRegenerateSimplerSwitchesToIntroEase() async throws {
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        vm.regenerateSimpler()
        XCTAssertEqual(vm.ease, .intro)
        await waitForStage(vm, .ready)
        XCTAssertEqual(vm.stage, .ready)
    }

    // MARK: - 本次记录数 = 无记录 → 有记录的新增

    func testSubmittedCountOnlyCountsNewRecords() async throws {
        // 预置全局：tea 已有记录（会）
        try world.run(UserKnownSystem(), context: .batch(
            words: [("tea", true)], source: "init"))

        let vm2 = VocabularyInitViewModel(world: world, settings: settings)
        vm2.clientOverride = MockClient(response: "I get up early and make some tea. I go to work.")
        await vm2.generate(ease: .medium)
        await waitForStage(vm2, .ready)

        XCTAssertTrue(vm2.isNewlyRecorded(vm2.words.first { $0.lemma == "work" }!),
                      "无记录词应算新增")
        XCTAssertFalse(vm2.isNewlyRecorded(vm2.words.first { $0.lemma == "tea" }!),
                       "已有记录词不算新增")

        vm2.submit()
        // 段落 11 个词，tea 已有记录 → 新增 10
        XCTAssertEqual(vm2.submittedCount, vm2.words.count - 1)
        XCTAssertEqual(vm2.newUnknownCount, 0, "无标不会的新增词")
        XCTAssertEqual(vm2.stage, .done)
    }

    // MARK: - 已有掌握度记录的词直接标绿/标红

    func testMarkStateReflectsGlobalMastery() async throws {
        // 预置全局掌握度：abandon 会（1.0）、battle 不会（0.0）
        try world.run(UserKnownSystem(), context: .batch(
            words: [("abandon", true), ("battle", false)], source: "init"))

        let vm2 = VocabularyInitViewModel(world: world, settings: settings)
        vm2.clientOverride = MockClient(response: "I abandon the plan and battle on.")
        await vm2.generate(ease: .medium)
        await waitForStage(vm2, .ready)

        // 已有记录：abandon → 绿（known），battle → 红（unknown）
        let abandon = try XCTUnwrap(vm2.words.first { $0.lemma == "abandon" })
        XCTAssertEqual(vm2.markState(for: abandon), .known)
        let battle = try XCTUnwrap(vm2.words.first { $0.lemma == "battle" })
        XCTAssertEqual(vm2.markState(for: battle), .unknown)
        // 无记录 → pending（待标记）
        let plan = try XCTUnwrap(vm2.words.first { $0.lemma == "plan" })
        XCTAssertEqual(vm2.markState(for: plan), .pending)
        // 绿（记录会）点击 → 红
        vm2.toggle(abandon)
        XCTAssertEqual(vm2.markState(for: abandon), .unknown)
        // 红（记录不会）点击 → 绿
        vm2.toggle(battle)
        XCTAssertEqual(vm2.markState(for: battle), .known)
        // 手动红的取消：灰 → 红 → 再点回灰（无记录）
        vm2.toggle(plan)
        XCTAssertEqual(vm2.markState(for: plan), .unknown)
        vm2.toggle(plan)
        XCTAssertEqual(vm2.markState(for: plan), .pending)
    }

    // MARK: - 新词优先：已有词过多 → 反馈重试

    func testGenerateRetriesWithFeedbackWhenKnownWordsMany() async throws {
        // 预置已会词 apple / battle
        try makeLemma("L1", "apple")
        try makeLemma("L2", "battle")
        try world.run(UserKnownSystem(), context: .batch(
            words: [("apple", true), ("battle", true)], source: "init"))
        vm.loadMastery()

        // 每次 generate = 规划 pass + 正文 两次调用；
        // 第一次正文过短（含已有词 apple/battle）→ 触发重试；第二次正文为长新词段落 → 合格停
        let mock = SequenceMockClient(responses: [
            "plan placeholder",                                   // 首轮规划 pass
            "I eat an apple and go to battle today.",             // 首轮正文（太短 + 已有词）
            "plan placeholder",                                   // 重试规划 pass
            longPara,                                             // 重试正文（108 词新词段落）
        ])
        vm.clientOverride = mock
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        let calls = await mock.calls
        let prompts = await mock.prompts
        XCTAssertEqual(calls, 4, "首轮不合格时应重试一次（规划+正文各两次）")
        XCTAssertTrue(prompts[3].contains("already knows"),
                      "重试正文 prompt 应带已有词反馈")
        XCTAssertTrue(vm.words.contains { $0.lemma == "quiet" },
                      "应使用重试后的段落（新词）")
        XCTAssertFalse(vm.words.contains { $0.lemma == "apple" },
                       "重试后不应再用已有词段落")
    }

    func testGenerateNoRetryWhenNewWordsEnough() async throws {
        // 无任何预置记录 + 长段落（108 词）→ 合格 → 单次生成（规划+正文），不重试
        let mock = SequenceMockClient(responses: [
            "plan placeholder",
            longPara,
            "Fallback paragraph that should never be used.",
        ])
        vm.clientOverride = mock
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        let calls = await mock.calls
        XCTAssertEqual(calls, 2, "长且新词足够时不应重试（仅规划+正文一次）")
    }

    func testNewWordCountExcludesKnownAndFunctionWords() throws {
        // 预置 apple 已会
        try makeLemma("L1", "apple")
        try world.run(UserKnownSystem(), context: .batch(
            words: [("apple", true)], source: "init"))
        vm.loadMastery()

        // the 功能词不计；apple 已会不计；quiet 新实词计 1
        vm.words = [
            InitWord(surface: "the", lemma: "the"),
            InitWord(surface: "apple", lemma: "apple"),
            InitWord(surface: "quiet", lemma: "quiet"),
        ]
        XCTAssertEqual(vm.newWordCount, 1)
    }

    // MARK: - 太短 / 新词不足 → 反馈重试（小模型适配）

    func testGenerateRetriesWithLengthFeedbackWhenTooShort() async throws {
        // 首轮只输出一句（3 词 < 100）→ 不合格，反馈带"太短"重试；次轮长段落合格停
        let mock = SequenceMockClient(responses: [
            "plan placeholder",                                   // 首轮规划 pass
            "I am happy.",                                        // 首轮正文（太短）
            "plan placeholder",                                   // 重试规划 pass
            longPara,                                             // 重试正文（108 词合格）
        ])
        vm.clientOverride = mock
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        let calls = await mock.calls
        let prompts = await mock.prompts
        XCTAssertEqual(calls, 4, "太短时应重试一次（规划+正文各两次）")
        XCTAssertTrue(prompts[3].contains("too short"), "重试 prompt 应带长度反馈")
        XCTAssertTrue(vm.words.contains { $0.lemma == "farmer" }, "应使用重试后的段落")
    }

    func testGenerateAcceptsLastAttemptWhenNeverPasses() async throws {
        // 3 轮都太短（mock 恒返回短句）→ 第 3 次直接接受，不无限重试、有结果
        let mock = SequenceMockClient(responses: [
            "plan", "I am happy.",
            "plan", "I am happy.",
            "plan", "I am happy.",
        ])
        vm.clientOverride = mock
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        let calls = await mock.calls
        XCTAssertEqual(calls, 6, "最多 3 轮（规划+正文各 3 次）")
        XCTAssertEqual(vm.stage, .ready, "都不合格也保底有段落可标")
        XCTAssertEqual(vm.paragraph, "I am happy.")
    }

    func testGeneratePicksLongestAcrossAttempts() async throws {
        // 3 轮都不合格（都 <100 词）→ 取最长的一轮，不浪费模型能力
        let mock = SequenceMockClient(responses: [
            "plan", "I am happy.",                                          // 轮1：3 词
            "plan", "The quiet farmer walks through the valley.",           // 轮2：7 词
            "plan", "The quiet farmer walks through the valley.",           // 轮3：7 词（与轮2平局）
        ])
        vm.clientOverride = mock
        await vm.generate(ease: .medium)
        await waitForStage(vm, .ready)

        let calls = await mock.calls
        XCTAssertEqual(calls, 6, "3 轮都不合格也应跑满 3 轮")
        XCTAssertEqual(vm.paragraph, "The quiet farmer walks through the valley.",
                       "应取最长一轮的段落（7 词 > 3 词）")
    }

    // MARK: - helpers

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func graphLemma(_ word: String) throws -> EntityID? {
        try world.graph.findLemmaId(byTextA: word)
    }

    private func graphMastery(_ lemmaId: EntityID) throws -> Double? {
        try world.graph.lemmaMastery(lemmaId: lemmaId)
    }
}
