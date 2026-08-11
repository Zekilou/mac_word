import XCTest
import GRDB
@testable import WordRecitingApp

/// 生成方式档位重构测试：
/// 1. 无纯规则档（已移除）；档位=进程内本地 / 远端 LLM
/// 2. 远端服务类型：Ollama（归远端）/ OpenAI API，切换时重置默认配置
/// 3. makeGenerator：进程内无模型文件 → 抛 engineUnavailable；有路径 → LocalLLMGenerator；远端 → LocalLLMGenerator
/// 4. OpenAICompatibleClient 连接失败 → 包装为 LLMClientError.connection（可读提示）
/// @ai: 类本身非 @MainActor；触达 VM 的方法单独标 @MainActor；settings 注入隔离 suite 避免污染 .standard。
final class GenerateViewModelTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        suiteName = "GenerateVM-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeVM() -> GenerateViewModel {
        GenerateViewModel(world: world, settings: AppSettings(defaults: defaults))
    }

    // MARK: - 档位与远端服务类型

    @MainActor func testDefaultTierIsRemoteOllama() {
        let vm = makeVM()
        XCTAssertEqual(vm.generatorTier, .remote)
        XCTAssertEqual(vm.remoteProvider, .ollama)
        XCTAssertEqual(vm.llmBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(vm.llmModel, "qwen2.5")
        XCTAssertTrue(vm.llmAPIKey.isEmpty)
    }

    @MainActor func testNoPureRuleTier() {
        let tiers = GeneratorTier.allCases.map(\.rawValue)
        XCTAssertFalse(tiers.contains { $0.contains("规则") })
        XCTAssertEqual(GeneratorTier.allCases.count, 2)
        XCTAssertEqual(GeneratorTier.processLocal.rawValue, "进程内本地")
        XCTAssertEqual(GeneratorTier.remote.rawValue, "远端 LLM")
    }

    @MainActor func testRemoteProviderDefaults() {
        XCTAssertEqual(RemoteProvider.ollama.defaultBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(RemoteProvider.ollama.defaultModel, "qwen2.5")
        XCTAssertFalse(RemoteProvider.ollama.needsAPIKey)

        XCTAssertEqual(RemoteProvider.openai.defaultBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(RemoteProvider.openai.defaultModel, "gpt-4o-mini")
        XCTAssertTrue(RemoteProvider.openai.needsAPIKey)
    }

    @MainActor func testApplyProviderDefaultsResetsConfig() {
        let vm = makeVM()
        vm.remoteProvider = .openai
        vm.applyProviderDefaults()
        XCTAssertEqual(vm.llmBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(vm.llmModel, "gpt-4o-mini")

        // 切回 Ollama：API Key 应清空
        vm.llmAPIKey = "sk-test"
        vm.remoteProvider = .ollama
        vm.applyProviderDefaults()
        XCTAssertEqual(vm.llmBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(vm.llmModel, "qwen2.5")
        XCTAssertTrue(vm.llmAPIKey.isEmpty)
    }

    // MARK: - makeGenerator

    @MainActor func testMakeGeneratorRemoteReturnsLocalLLMGenerator() throws {
        let vm = makeVM()
        let generator = try vm.makeGenerator()
        XCTAssertTrue(generator is LocalLLMGenerator)
    }

    @MainActor func testMakeGeneratorProcessLocalWithoutModelThrows() {
        let vm = makeVM()
        vm.generatorTier = .processLocal
        XCTAssertThrowsError(try vm.makeGenerator()) { error in
            guard case GenerateError.engineUnavailable = error else {
                return XCTFail("应为 engineUnavailable，实际 \(error)")
            }
        }
    }

    @MainActor func testMakeGeneratorProcessLocalWithModelReturnsGenerator() throws {
        let vm = makeVM()
        vm.generatorTier = .processLocal
        vm.settings.localModelPath = "/tmp/test.gguf"
        let generator = try vm.makeGenerator()
        XCTAssertTrue(generator is LocalLLMGenerator)
    }

    @MainActor func testPersistSettingsRoundTrip() {
        let vm = makeVM()
        vm.remoteProvider = .openai
        vm.applyProviderDefaults()
        vm.llmAPIKey = "sk-test"
        vm.persistSettings()

        // 新实例读回同一 settings
        let reloaded = GenerateViewModel(world: world, settings: AppSettings(defaults: defaults))
        XCTAssertEqual(reloaded.remoteProvider, .openai)
        XCTAssertEqual(reloaded.llmBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(reloaded.llmAPIKey, "sk-test")
    }

    // MARK: - 连接错误包装

    /// 连一个必然拒绝的地址：应包装为 LLMClientError.connection（带可读提示），而不是裸 URLError。
    func testConnectionFailureIsWrapped() async {
        let client = OpenAICompatibleClient(
            baseURL: "http://127.0.0.1:1/v1", apiKey: nil, model: "qwen2.5")
        do {
            _ = try await client.complete(prompt: "hello", maxTokens: 10, temperature: 0)
            XCTFail("应抛错")
        } catch let LLMClientError.connection(detail) {
            XCTAssertTrue(detail.contains("127.0.0.1"))
            XCTAssertTrue(detail.contains("ollama"))
        } catch {
            XCTFail("应为 LLMClientError.connection，实际 \(error)")
        }
    }

    // MARK: - 随机选词（筛选学过/未学过 + 数量 + 去重）

    /// 3 张卡：card-1 已学（reps=1），card-2/3 未学。
    @MainActor
    private func seedRandomDeck() throws {
        let now = Date()
        for (id, text) in [("lemma-1", "abandon"), ("lemma-2", "battle"), ("lemma-3", "happy")] {
            try world.registry.insertNode(id: id, kind: .lemma, createdAt: now)
            try world.registry.upsertComponent(TextComponent(
                entityId: id, textA: text, textB: "def", language: "en"))
        }
        for id in ["card-1", "card-2", "card-3"] {
            try world.registry.insertNode(id: id, kind: .card, createdAt: now)
        }
        try world.registry.insertNode(id: "deck-1", kind: .deck, createdAt: now)
        for (i, cardId) in ["card-1", "card-2", "card-3"].enumerated() {
            try world.registry.insertEdge(
                id: "has-\(cardId)", srcId: "deck-1", dstId: cardId, rel: .has, createdAt: now)
            try world.registry.insertEdge(
                id: "inst-\(cardId)", srcId: cardId, dstId: "lemma-\(i + 1)",
                rel: .instantiates, createdAt: now)
        }
        try world.registry.upsertComponent(DeckMetaComponent(
            entityId: "deck-1", name: "D", sourceKind: "csv", sourcePath: nil, importedAt: now))
        // card-1 已学过 1 次
        try world.registry.upsertComponent(ScheduleStateComponent(
            entityId: "card-1", stability: 3, difficulty: 2.5, dueAt: now,
            intervalDays: 3, reps: 1, lapses: 0, lastRating: 3,
            lastReviewedAt: now, schedulerId: "sm-2", queue: "review", customDataJson: nil))
    }

    @MainActor func testRandomPickUnlearnedOnly() throws {
        try seedRandomDeck()
        let vm = makeVM()
        vm.selectDeck("deck-1")
        vm.wordFilter = .unlearned
        vm.randomCount = 99  // 超出池大小 → 全选
        let picked = vm.randomPick()
        XCTAssertEqual(picked.count, 2, "未学过应只有 card-2/3")
        XCTAssertFalse(picked.contains("lemma-1"), "已学的 lemma-1 不应被选出")
        XCTAssertEqual(vm.pickedLemmaIds.count, 2)
    }

    @MainActor func testRandomPickLearnedOnly() throws {
        try seedRandomDeck()
        let vm = makeVM()
        vm.selectDeck("deck-1")
        vm.wordFilter = .learned
        XCTAssertEqual(vm.randomPick(), ["lemma-1"])
    }

    @MainActor func testRandomPickClampsCountToOne() throws {
        try seedRandomDeck()
        let vm = makeVM()
        vm.selectDeck("deck-1")
        vm.wordFilter = .learned
        vm.randomCount = 0
        XCTAssertEqual(vm.randomPick().count, 1, "数量 0 应钳制为 1")
    }

    @MainActor func testRandomPickUnionsWithoutDuplicate() throws {
        try seedRandomDeck()
        let vm = makeVM()
        vm.selectDeck("deck-1")
        vm.pickedLemmaIds = ["lemma-1"]  // 已手动选了一个
        vm.wordFilter = .unlearned
        vm.randomCount = 2
        vm.randomPick()
        // 未学池恰好 2 个 → 全部并入，总 3 个且不重复
        XCTAssertEqual(vm.pickedLemmaIds.count, 3)
    }

    @MainActor func testRandomPickWithoutDeckReturnsEmpty() {
        let vm = makeVM()
        XCTAssertTrue(vm.randomPick().isEmpty)
    }

    // MARK: - Agentic 进度与跳过词

    @MainActor func testApplyProgressEmbeddingStageAndWord() {
        let vm = makeVM()
        vm.applyProgress(.stage(.embedding))
        XCTAssertEqual(vm.genStage, .embedding)
        vm.applyProgress(.word(done: 2, total: 5, word: "battle"))
        XCTAssertEqual(vm.embedWordProgress, EmbedWordProgress(done: 2, total: 5, word: "battle"))
    }

    @MainActor func testSkippedReasonLookup() {
        let vm = makeVM()
        vm.lastSkipped = [SkippedWord(word: "abandon", reason: "no fit")]
        XCTAssertEqual(vm.skippedReason(for: "abandon"), "no fit")
        XCTAssertNil(vm.skippedReason(for: "battle"))
    }

    // MARK: - 思考日志 + Token 指标

    @MainActor func testThoughtEventsUpsertLog() {
        let vm = makeVM()
        vm.applyProgress(.thought(GenThought(
            id: "strategy", kind: .strategy, message: "正在制定生成策略…", detail: nil, status: .running)))
        XCTAssertEqual(vm.thinkingLog.count, 1)
        vm.applyProgress(.thought(GenThought(
            id: "strategy", kind: .strategy, message: "策略：先写后改写", detail: nil, status: .done)))
        XCTAssertEqual(vm.thinkingLog.count, 1, "同 id 应 upsert")
        XCTAssertEqual(vm.thinkingLog[0].message, "策略：先写后改写")
        XCTAssertEqual(vm.thinkingLog[0].status, .done)
    }

    @MainActor func testStreamStatsTracksTokensAndRate() async throws {
        let vm = makeVM()
        vm.applyProgress(.stage(.generating))
        vm.applyProgress(.token("Hello"))
        let s1 = vm.streamStats
        XCTAssertEqual(s1.tokens, 1)
        XCTAssertNotNil(s1.firstTokenLatency)
        XCTAssertGreaterThanOrEqual(s1.rate, 0)
        try await Task.sleep(nanoseconds: 10_000_000)   // 保证 elapsed > 0，速率断言不 flaky
        vm.applyProgress(.token(" world"))
        XCTAssertEqual(vm.streamStats.tokens, 2)
        XCTAssertGreaterThan(vm.streamStats.rate, 0, "速率应随 token 增长")
    }

    @MainActor func testStopCancelsGeneration() async throws {
        let vm = makeVM()
        // 无活动任务时 stop 不崩
        vm.stopGenerating()
        XCTAssertFalse(vm.isGenerating)
    }

    @MainActor func testTokenStreamStripsMarkerLines() {
        let vm = makeVM()
        vm.applyProgress(.token("===ARTICLE_START===\nHello."))
        XCTAssertEqual(vm.streamedText, "Hello.", "实时展示应剥离独立标记行")
        vm.applyProgress(.token(" world\n===ARTICLE_END==="))
        XCTAssertEqual(vm.streamedText, "Hello. world", "结束标记行也应剥离")
    }
}
