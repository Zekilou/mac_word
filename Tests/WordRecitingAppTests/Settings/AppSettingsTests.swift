import XCTest
import GRDB
@testable import WordRecitingApp

/// AppSettings（UserDefaults 持久化）测试。
/// @ai: 用独立 suite 避免污染 .standard；@MainActor（AppSettings 是 @MainActor）。
final class AppSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    @MainActor func testDefaults() {
        let settings = makeSettings()
        XCTAssertEqual(settings.generatorTier, .remote)
        XCTAssertEqual(settings.remoteProvider, .ollama)
        XCTAssertEqual(settings.llmModel, "qwen2.5")
        XCTAssertEqual(settings.llmBaseURL, "http://localhost:11434/v1")
        XCTAssertNil(settings.localModelPath)
        XCTAssertEqual(settings.schedulerID, .sm2)
    }

    @MainActor func testPersistAndReload() {
        let settings = makeSettings()
        settings.generatorTier = .processLocal
        settings.remoteProvider = .openai
        settings.llmModel = "gpt-4o-mini"
        settings.llmBaseURL = "https://api.openai.com/v1"
        settings.llmAPIKey = "sk-test"
        settings.localModelPath = "/tmp/foo.gguf"
        settings.schedulerID = .fsrsV4

        // 新实例从同一个 defaults 读回
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.generatorTier, .processLocal)
        XCTAssertEqual(reloaded.remoteProvider, .openai)
        XCTAssertEqual(reloaded.llmModel, "gpt-4o-mini")
        XCTAssertEqual(reloaded.llmBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(reloaded.llmAPIKey, "sk-test")
        XCTAssertEqual(reloaded.localModelPath, "/tmp/foo.gguf")
        XCTAssertEqual(reloaded.schedulerID, .fsrsV4)
    }

    @MainActor func testApplyProviderDefaults() {
        let settings = makeSettings()
        settings.remoteProvider = .openai
        settings.applyProviderDefaults()
        XCTAssertEqual(settings.llmBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(settings.llmModel, "gpt-4o-mini")

        settings.llmAPIKey = "sk-x"
        settings.remoteProvider = .ollama
        settings.applyProviderDefaults()
        XCTAssertEqual(settings.llmBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(settings.llmModel, "qwen2.5")
        XCTAssertTrue(settings.llmAPIKey.isEmpty)   // Ollama 不需要 Key，清空
    }

    @MainActor func testResetClearsAll() {
        let settings = makeSettings()
        settings.llmModel = "custom"
        settings.localModelPath = "/tmp/x.gguf"
        settings.reset()
        XCTAssertEqual(settings.llmModel, "qwen2.5")  // 回默认
        XCTAssertNil(settings.localModelPath)
    }

    // MARK: - 逐词融入验证强度

    @MainActor func testEmbeddingVerificationPersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.embeddingVerification, .standard, "默认应为 standard")
        settings.embeddingVerification = .strict
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.embeddingVerification, .strict)
    }

    // MARK: - 词向量来源（内置 GloVe / 远端 API）

    @MainActor func testEmbeddingSourcePersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.embeddingSource, .builtinGloVe, "默认内置 GloVe")
        XCTAssertEqual(settings.embeddingModel, "nomic-embed-text", "远端模型默认值")

        settings.embeddingSource = .remoteAPI
        settings.embeddingModel = "text-embedding-3-small"
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.embeddingSource, .remoteAPI)
        XCTAssertEqual(reloaded.embeddingModel, "text-embedding-3-small")
    }

    @MainActor func testEmbeddingSourceResetClears() {
        let settings = makeSettings()
        settings.embeddingSource = .remoteAPI
        settings.embeddingModel = "custom-embed"
        settings.reset()
        XCTAssertEqual(settings.embeddingSource, .builtinGloVe, "reset 回默认内置")
        XCTAssertEqual(settings.embeddingModel, "nomic-embed-text")
    }

    // MARK: - Agent sidecar 管线开关

    @MainActor func testUseAgentSidecarPersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.useAgentSidecar, "默认关闭（sidecar 未打包前仅开发可用）")
        settings.useAgentSidecar = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.useAgentSidecar)
        let reset = makeSettings()
        reset.useAgentSidecar = true
        reset.reset()
        XCTAssertFalse(reset.useAgentSidecar, "reset 回默认关闭")
    }

    // MARK: - 生成上下文（上下文窗口 + 输出上限）

    @MainActor func testContextWindowPersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.contextWindow, 2048, "默认 2048（本地 llama.cpp n_ctx）")
        settings.contextWindow = 8192
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.contextWindow, 8192, "改值持久化")
        reloaded.reset()
        XCTAssertEqual(reloaded.contextWindow, 2048, "reset 回默认")
    }

    @MainActor func testMaxOutputTokensPersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.maxOutputTokens, 0, "默认 0 = 自动按字数动态计算")
        settings.maxOutputTokens = 2048
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.maxOutputTokens, 2048)
        reloaded.reset()
        XCTAssertEqual(reloaded.maxOutputTokens, 0, "reset 回自动")
    }

    // MARK: - API 配置（多条增删改 + 激活）

    @MainActor func testAPIConfigsPersistAndActivate() {
        let settings = AppSettings(defaults: defaults)
        // 空时默认一条
        XCTAssertEqual(settings.apiConfigs.count, 1, "无配置时应有默认一条")
        XCTAssertEqual(settings.activeAPIConfig.provider, .ollama)

        // 添加第二条并激活
        let openAI = APIConfig(
            id: "cfg-openai", name: "OpenAI 云端", provider: .openai,
            model: "gpt-4o-mini", baseURL: "https://api.openai.com/v1", apiKey: "sk-test")
        settings.upsertAPIConfig(openAI)
        XCTAssertEqual(settings.apiConfigs.count, 2)
        XCTAssertEqual(settings.activeAPIConfigID, "cfg-openai", "新增应设为当前生效")
        XCTAssertEqual(settings.llmModel, "gpt-4o-mini", "激活应同步远端字段")
        XCTAssertEqual(settings.llmAPIKey, "sk-test")

        // 编辑已存在的（同 id 覆盖）
        var edited = openAI
        edited.model = "gpt-4o"
        settings.upsertAPIConfig(edited)
        XCTAssertEqual(settings.apiConfigs.count, 2, "同 id 应覆盖不新增")
        XCTAssertEqual(settings.activeAPIConfig.model, "gpt-4o")

        // 删除激活项 → 切到剩余的第一条
        settings.removeAPIConfig(id: "cfg-openai")
        XCTAssertEqual(settings.apiConfigs.count, 1)
        XCTAssertEqual(settings.activeAPIConfigID, settings.apiConfigs.first?.id)
        XCTAssertEqual(settings.remoteProvider, .ollama, "删除后应回到剩余配置")

        // 持久化：新实例读回
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.apiConfigs.count, 1)
        XCTAssertEqual(reloaded.apiConfigs[0].name, "默认")
    }

    @MainActor func testActivateAPIConfigSwitchesFields() {
        let settings = AppSettings(defaults: defaults)
        let openAI = APIConfig(
            id: "o", name: "OpenAI", provider: .openai,
            model: "gpt-4o", baseURL: "https://api.openai.com/v1", apiKey: "sk-1")
        settings.upsertAPIConfig(openAI)
        let ollama = APIConfig(
            id: "l", name: "本地", provider: .ollama,
            model: "qwen2.5", baseURL: "http://localhost:11434/v1", apiKey: "")
        settings.upsertAPIConfig(ollama)

        settings.activateAPIConfig(id: "o")
        XCTAssertEqual(settings.remoteProvider, .openai)
        XCTAssertEqual(settings.llmModel, "gpt-4o")
        settings.activateAPIConfig(id: "l")
        XCTAssertEqual(settings.remoteProvider, .ollama)
        XCTAssertEqual(settings.llmAPIKey, "", "Ollama 不应保留 Key")
    }

    // MARK: - 思考型模型类型（探测结果持久化 + 手动覆盖）

    /// 探测结果写回 isThinking → 新实例读回（持久化）；编辑保留原探测值。
    @MainActor func testAPIConfigIsThinkingPersistsAndSurvivesEdit() {
        let settings = makeSettings()
        var config = settings.activeAPIConfig
        config.isThinking = true  // 探测结果/手动覆盖
        settings.upsertAPIConfig(config)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.activeAPIConfig.isThinking, true, "探测结果应持久化")

        // 手动覆盖：改为普通型
        var overridden = reloaded.activeAPIConfig
        overridden.isThinking = false
        reloaded.upsertAPIConfig(overridden)
        XCTAssertEqual(reloaded.activeAPIConfig.isThinking, false, "手动覆盖应生效")
    }

    /// 旧数据（无 isThinking 字段）解码为 nil（未探测），不崩溃。
    @MainActor func testAPIConfigMissingIsThinkingDefaultsNil() throws {
        // 手工写入不含 isThinking 字段的旧 JSON
        let oldJSON = """
        [{"id":"default","name":"默认","provider":"ollama",
          "model":"qwen2.5","baseURL":"http://localhost:11434/v1","apiKey":""}]
        """
        defaults.set(Data(oldJSON.utf8), forKey: "settings.apiConfigs")
        let settings = makeSettings()
        XCTAssertEqual(settings.apiConfigs.count, 1)
        XCTAssertNil(settings.apiConfigs[0].isThinking, "旧数据解码为未探测")
    }

    // MARK: - 本地 agent 增强（useLocalAgentEnhancement / llamaServerBinaryPath / llamaServerLifecycle）

    @MainActor func testLocalAgentEnhancementDefaults() {
        let settings = makeSettings()
        XCTAssertFalse(settings.useLocalAgentEnhancement, "默认关闭")
        XCTAssertNil(settings.llamaServerBinaryPath, "默认未下载")
        XCTAssertEqual(settings.llamaServerLifecycle, .idleTimeout, "默认闲置超时停")
    }

    @MainActor func testLocalAgentEnhancementPersists() {
        let settings = makeSettings()
        settings.useLocalAgentEnhancement = true
        settings.llamaServerBinaryPath = "/tmp/llama-server"
        settings.llamaServerLifecycle = .persistent

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.useLocalAgentEnhancement)
        XCTAssertEqual(reloaded.llamaServerBinaryPath, "/tmp/llama-server")
        XCTAssertEqual(reloaded.llamaServerLifecycle, .persistent)
    }

    @MainActor func testResetClearsLocalAgentEnhancement() {
        let settings = makeSettings()
        settings.useLocalAgentEnhancement = true
        settings.llamaServerBinaryPath = "/tmp/llama-server"
        settings.llamaServerLifecycle = .perGenerate
        settings.reset()

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.useLocalAgentEnhancement)
        XCTAssertNil(reloaded.llamaServerBinaryPath)
        XCTAssertEqual(reloaded.llamaServerLifecycle, .idleTimeout, "reset 回默认")
    }

    @MainActor func testLlamaServerBinaryPathNilRemoves() {
        let settings = makeSettings()
        settings.llamaServerBinaryPath = "/tmp/llama-server"
        XCTAssertEqual(settings.llamaServerBinaryPath, "/tmp/llama-server")
        settings.llamaServerBinaryPath = nil
        XCTAssertNil(settings.llamaServerBinaryPath, "设 nil 应移除 key")
    }
}
