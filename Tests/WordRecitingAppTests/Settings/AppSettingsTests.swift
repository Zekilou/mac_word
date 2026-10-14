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

    // MARK: - API Key 机密存储（回归）

    /// 回归：API Key **不得**以明文写进 UserDefaults。
    /// @ai: 旧实现 `defaults.set(key, forKey: "settings.llmAPIKey")` → plist 明文，
    ///      备份/任何读该目录的进程都能拿到。现走 SecretStore（生产=Keychain）。
    @MainActor func testAPIKeyIsNotPersistedInUserDefaults() {
        let settings = makeSettings()
        settings.llmAPIKey = "sk-secret-123"

        XCTAssertEqual(settings.llmAPIKey, "sk-secret-123", "读回应仍是完整 Key")
        XCTAssertNil(defaults.string(forKey: "settings.llmAPIKey"),
                     "UserDefaults 里不得残留明文 Key")
        XCTAssertNil(defaults.data(forKey: "settings.llmAPIKey"))
    }

    /// 回归：历史版本存在 UserDefaults 的明文 Key 必须迁移到机密存储并从盘上清除。
    @MainActor func testLegacyPlaintextAPIKeyIsMigratedOutOfUserDefaults() {
        // 模拟旧版本写下的明文
        defaults.set("sk-legacy-plain", forKey: "settings.llmAPIKey")

        let settings = makeSettings()

        XCTAssertEqual(settings.llmAPIKey, "sk-legacy-plain", "旧 Key 应可继续读到")
        XCTAssertNil(defaults.string(forKey: "settings.llmAPIKey"),
                     "迁移后必须删掉 UserDefaults 里的明文")
    }

    /// 恢复默认设置时必须一并清除机密存储里的 Key。
    @MainActor func testResetClearsAPIKeyFromSecretStore() {
        let settings = makeSettings()
        settings.llmAPIKey = "sk-to-be-cleared"
        settings.reset()

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.llmAPIKey.isEmpty, "reset 后 Key 应被清除（Keychain 不会随 defaults 清空）")
    }

    @MainActor func testLlamaServerBinaryPathNilRemoves() {
        let settings = makeSettings()
        settings.llamaServerBinaryPath = "/tmp/llama-server"
        XCTAssertEqual(settings.llamaServerBinaryPath, "/tmp/llama-server")
        settings.llamaServerBinaryPath = nil
        XCTAssertNil(settings.llamaServerBinaryPath, "设 nil 应移除 key")
    }

    // MARK: - Observation 可观测性（回归）

    /// 回归：**每一项**设置都要能被独立观测到，否则对应控件不刷新。
    /// @ai: AppSettings 全部属性都是 UserDefaults 支撑的 computed property，
    ///      `@Observable` 只为 stored property 生成观察支持 → 旧实现写设置不触发任何回调，
    ///      导致「切到进程内本地不显示本地 agent 增强区」「embedding 远端输入框不出现」
    ///      「onChange 完全不触发」等一整类失效。修复用统一 changeToken：getter access()、setter 自增。
    ///      注意必须**逐项隔离**验证：若在一个 tracking 块里读全部属性，
    ///      任何一项有 track() 就会让所有断言通过（测试形同虚设）。
    @MainActor func testSettingWriteIsObservable() {
        let settings = makeSettings()
        // (名称, 只读该项以建立依赖, 写入)
        let cases: [(String, () -> Void, () -> Void)] = [
            ("generatorTier", { _ = settings.generatorTier }, { settings.generatorTier = .processLocal }),
            ("remoteProvider", { _ = settings.remoteProvider }, { settings.remoteProvider = .openai }),
            ("llmModel", { _ = settings.llmModel }, { settings.llmModel = "gpt-4o-mini" }),
            ("llmBaseURL", { _ = settings.llmBaseURL }, { settings.llmBaseURL = "https://example.com/v1" }),
            ("llmAPIKey", { _ = settings.llmAPIKey }, { settings.llmAPIKey = "sk-test" }),
            ("localModelPath", { _ = settings.localModelPath }, { settings.localModelPath = "/tmp/m.gguf" }),
            ("schedulerID", { _ = settings.schedulerID }, { settings.schedulerID = .sm2Frequency }),
            ("wordScoringID", { _ = settings.wordScoringID }, { settings.wordScoringID = .criticalWords }),
            ("embeddingVerification", { _ = settings.embeddingVerification }, { settings.embeddingVerification = .strict }),
            ("embeddingSource", { _ = settings.embeddingSource }, { settings.embeddingSource = .remoteAPI }),
            ("embeddingModel", { _ = settings.embeddingModel }, { settings.embeddingModel = "nomic-embed-text" }),
            ("useAgentSidecar", { _ = settings.useAgentSidecar }, { settings.useAgentSidecar = true }),
            ("useLocalAgentEnhancement", { _ = settings.useLocalAgentEnhancement }, { settings.useLocalAgentEnhancement = true }),
            ("llamaServerBinaryPath", { _ = settings.llamaServerBinaryPath }, { settings.llamaServerBinaryPath = "/tmp/bin" }),
            ("llamaServerLifecycle", { _ = settings.llamaServerLifecycle }, { settings.llamaServerLifecycle = .persistent }),
            ("contextWindow", { _ = settings.contextWindow }, { settings.contextWindow = 4096 }),
            ("maxOutputTokens", { _ = settings.maxOutputTokens }, { settings.maxOutputTokens = 900 }),
            ("defaultTargetCount", { _ = settings.defaultTargetCount }, { settings.defaultTargetCount = 12 }),
            ("defaultArticleLength", { _ = settings.defaultArticleLength }, { settings.defaultArticleLength = 500 }),
            ("defaultWordFilter", { _ = settings.defaultWordFilter }, { settings.defaultWordFilter = "unlearned" }),
            ("defaultRandomCount", { _ = settings.defaultRandomCount }, { settings.defaultRandomCount = 8 }),
            ("appearanceMode", { _ = settings.appearanceMode }, { settings.appearanceMode = .dark }),
            ("apiConfigs", { _ = settings.apiConfigs }, {
                settings.apiConfigs = [APIConfig(
                    id: "x", name: "x", provider: .ollama,
                    model: "qwen2.5", baseURL: "http://localhost:11434/v1", apiKey: "")]
            }),
            ("activeAPIConfigID", { _ = settings.activeAPIConfigID }, { settings.activeAPIConfigID = "x" }),
        ]
        for (name, read, write) in cases {
            let fired = FiredBox()
            withObservationTracking {
                read()   // 只读该项 → 依赖只落在该项上
            } onChange: {
                fired.value = true
            }
            write()
            XCTAssertTrue(fired.value, "写入 \(name) 应触发 Observation 回调（否则 UI 不刷新）")
        }
    }
}

/// onChange 回调在非隔离上下文执行，用引用容器承载结果（避免 Swift 6 捕获 var 报错）。
private final class FiredBox: @unchecked Sendable {
    var value = false
}
