import Foundation
import Observation

/// 应用设置（UserDefaults 持久化）。
/// 集中管理：LLM 生成配置（档位 / 远端服务 / 模型路径）+ 复习调度算法。
/// @ai: 设置页与生成页共用；UI 通过 SettingsViewModel 读写，不改裸 defaults。
@MainActor
@Observable
final class AppSettings {

    /// 全局共享实例（App 生命周期内单例）。
    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyPaths()
    }

    /// 1.0.0 改名后，把 UserDefaults 里指向旧目录的绝对路径迁到新目录（幂等）。
    /// @ai: 目录迁移在 AppIdentity.ensureSupportDirectory 里做，持久化路径不会自动跟着改；
    ///      不改就会让本地模型/二进制指向已不存在的旧目录（本地模型"无法使用"）。
    private func migrateLegacyPaths() {
        for key in [Key.localModelPath, Key.llamaServerBinaryPath] {
            guard let raw = defaults.string(forKey: key),
                  let migrated = AppIdentity.migrateLegacyPath(raw),
                  migrated != raw else { continue }
            defaults.set(migrated, forKey: key)
        }
    }

    // MARK: - 键名

    private enum Key {
        static let generatorTier = "settings.generatorTier"
        static let remoteProvider = "settings.remoteProvider"
        static let llmModel = "settings.llmModel"
        static let llmBaseURL = "settings.llmBaseURL"
        static let llmAPIKey = "settings.llmAPIKey"
        static let localModelPath = "settings.localModelPath"
        static let schedulerID = "settings.schedulerID"
        static let embeddingVerification = "settings.embeddingVerification"
        static let contextWindow = "settings.contextWindow"
        static let maxOutputTokens = "settings.maxOutputTokens"
        static let defaultTargetCount = "settings.defaultTargetCount"
        static let defaultArticleLength = "settings.defaultArticleLength"
        static let defaultWordFilter = "settings.defaultWordFilter"
        static let defaultRandomCount = "settings.defaultRandomCount"
        static let wordScoringID = "settings.wordScoringID"
        static let appearanceMode = "settings.appearanceMode"
        static let apiConfigs = "settings.apiConfigs"
        static let activeAPIConfigID = "settings.activeAPIConfigID"
        static let embeddingSource = "settings.embeddingSource"
        static let embeddingModel = "settings.embeddingModel"
        static let useAgentSidecar = "settings.useAgentSidecar"
        static let useLocalAgentEnhancement = "settings.useLocalAgentEnhancement"
        static let llamaServerBinaryPath = "settings.llamaServerBinaryPath"
        static let llamaServerLifecycle = "settings.llamaServerLifecycle"
    }

    // MARK: - 生成配置

    /// 默认生成方式（进程内本地 / 远端 LLM）。默认远端，进程内引擎接入后用户可在设置切换。
    var generatorTier: GeneratorTier {
        get {
            guard let raw = defaults.string(forKey: Key.generatorTier),
                  let tier = GeneratorTier(rawValue: raw) else { return .remote }
            return tier
        }
        set { defaults.set(newValue.rawValue, forKey: Key.generatorTier) }
    }

    /// 远端服务类型（Ollama / OpenAI API）。
    var remoteProvider: RemoteProvider {
        get {
            guard let raw = defaults.string(forKey: Key.remoteProvider),
                  let provider = RemoteProvider(rawValue: raw) else { return .ollama }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Key.remoteProvider) }
    }

    var llmModel: String {
        get { defaults.string(forKey: Key.llmModel) ?? RemoteProvider.ollama.defaultModel }
        set { defaults.set(newValue, forKey: Key.llmModel) }
    }

    var llmBaseURL: String {
        get { defaults.string(forKey: Key.llmBaseURL) ?? RemoteProvider.ollama.defaultBaseURL }
        set { defaults.set(newValue, forKey: Key.llmBaseURL) }
    }

    var llmAPIKey: String {
        get { defaults.string(forKey: Key.llmAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Key.llmAPIKey) }
    }

    // MARK: - 进程内模型

    /// 当前选中的进程内 GGUF 模型文件路径。
    var localModelPath: String? {
        get { defaults.string(forKey: Key.localModelPath) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.localModelPath)
            } else {
                defaults.removeObject(forKey: Key.localModelPath)
            }
        }
    }

    /// 已选模型文件是否真实可用（存在且是文件）。
    /// @ai: 只读判断，供设置页提示；不改变 localModelPath 的原值语义。
    var localModelPathIsUsable: Bool {
        guard let path = localModelPath, !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return !isDir.boolValue
    }

    // MARK: - 复习调度

    /// 复习调度算法（当前 StudySystem 固定 SM-2；FSRS 接入后生效）。
    var schedulerID: SchedulerID {
        get {
            guard let raw = defaults.string(forKey: Key.schedulerID),
                  let sid = SchedulerID(rawValue: raw) else { return .sm2 }
            return sid
        }
        set { defaults.set(newValue.rawValue, forKey: Key.schedulerID) }
    }

    /// 选词打分策略（默认随机，与升级前一致）。
    var wordScoringID: WordScoringID {
        get {
            guard let raw = defaults.string(forKey: Key.wordScoringID),
                  let id = WordScoringID(rawValue: raw) else { return .random }
            return id
        }
        set { defaults.set(newValue.rawValue, forKey: Key.wordScoringID) }
    }

    // MARK: - 逐词融入验证强度

    /// generate-rewrite 逐词融入的验证强度（light/standard/strict）。
    var embeddingVerification: EmbeddingVerification {
        get {
            guard let raw = defaults.string(forKey: Key.embeddingVerification),
                  let level = EmbeddingVerification(rawValue: raw) else { return .standard }
            return level
        }
        set { defaults.set(newValue.rawValue, forKey: Key.embeddingVerification) }
    }

    // MARK: - 词向量来源（RAG 选锚）

    /// 词向量来源：内置 GloVe（默认，随 app 分发）/ 远端 embeddings API。
    var embeddingSource: EmbeddingSource {
        get {
            guard let raw = defaults.string(forKey: Key.embeddingSource),
                  let source = EmbeddingSource(rawValue: raw) else { return .builtinGloVe }
            return source
        }
        set { defaults.set(newValue.rawValue, forKey: Key.embeddingSource) }
    }

    /// 远端 embedding 模型名（仅 embeddingSource == .remoteAPI 生效）。
    /// @ai: 服务地址与 Key 复用上方远端 API 配置（activeAPIConfig）；Ollama 常用 nomic-embed-text。
    var embeddingModel: String {
        get { defaults.string(forKey: Key.embeddingModel) ?? "nomic-embed-text" }
        set { defaults.set(newValue, forKey: Key.embeddingModel) }
    }

    /// 远端档是否走 Agent sidecar 管线（OpenAI Agents SDK 编排，含 guardrail 拦截与自动修正）。
    /// @ai: 默认关闭——sidecar 未打包（Task 7 前）仅开发环境可用；开启后不可用时自动回退本地管线。
    var useAgentSidecar: Bool {
        get { defaults.object(forKey: Key.useAgentSidecar) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.useAgentSidecar) }
    }

    // MARK: - 本地 agent 增强（进程内档 .processLocal 走 sidecar）

    /// 进程内本地档是否启用「本地 agent 增强」：spawn llama-server 监听 localhost:port，
    /// sidecar 指向它，复用远端 sidecar 同款 guardrail + 自动修正循环。
    /// @ai: 默认关闭——需先下载 llama-server 二进制；不可用时回退 LocalLLMGenerator。
    ///      与 useAgentSidecar 互不干扰：useAgentSidecar 管远端档，本开关管进程内档。
    var useLocalAgentEnhancement: Bool {
        get { defaults.object(forKey: Key.useLocalAgentEnhancement) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.useLocalAgentEnhancement) }
    }

    /// 已下载的 llama-server 二进制路径（nil = 未下载）。
    /// @ai: 由 LlamaServerDownloader 下载后写入；设置页据此显示「下载/已就绪」状态。
    var llamaServerBinaryPath: String? {
        get { defaults.string(forKey: Key.llamaServerBinaryPath) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.llamaServerBinaryPath)
            } else {
                defaults.removeObject(forKey: Key.llamaServerBinaryPath)
            }
        }
    }

    /// llama-server 进程生命周期策略（常驻 / 按生成启停 / 闲置超时停）。
    var llamaServerLifecycle: LlamaServerLifecycle {
        get {
            guard let raw = defaults.string(forKey: Key.llamaServerLifecycle),
                  let v = LlamaServerLifecycle(rawValue: raw) else { return .idleTimeout }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: Key.llamaServerLifecycle) }
    }

    // MARK: - 生成上下文（动态输出上限 + 窗口压缩）

    /// 模型上下文窗口（tokens）：长 prompt 压缩判断依据；
    /// 本地 llama.cpp 默认 n_ctx=2048，远端按模型调大（如 qwen2.5~32K / gpt-4o~128K）。
    var contextWindow: Int {
        get { defaults.object(forKey: Key.contextWindow) as? Int ?? 2048 }
        set { defaults.set(newValue, forKey: Key.contextWindow) }
    }

    /// 输出 token 上限（0 = 自动按目标字数动态计算：字数×1.5+200，并 clamp 到上下文窗口 3/4；>0 = 用户固定覆盖）。
    var maxOutputTokens: Int {
        get { defaults.object(forKey: Key.maxOutputTokens) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: Key.maxOutputTokens) }
    }

    // MARK: - 生成默认

    /// 默认目标词数量（造文默认选词个数）。
    var defaultTargetCount: Int {
        get { defaults.object(forKey: Key.defaultTargetCount) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: Key.defaultTargetCount) }
    }

    /// 默认文章字数（造文默认长度，供提示词使用）。
    var defaultArticleLength: Int {
        get { defaults.object(forKey: Key.defaultArticleLength) as? Int ?? 400 }
        set { defaults.set(newValue, forKey: Key.defaultArticleLength) }
    }

    // MARK: - 选词默认

    /// 默认选词过滤范围（WordFilter rawValue）。
    var defaultWordFilter: String {
        get { defaults.string(forKey: Key.defaultWordFilter) ?? "all" }
        set { defaults.set(newValue, forKey: Key.defaultWordFilter) }
    }

    /// 默认随机选词数量。
    var defaultRandomCount: Int {
        get { defaults.object(forKey: Key.defaultRandomCount) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: Key.defaultRandomCount) }
    }

    // MARK: - 显示

    /// 外观模式（跟随系统/浅色/深色）。
    var appearanceMode: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: Key.appearanceMode),
                  let mode = AppearanceMode(rawValue: raw) else { return .auto }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appearanceMode) }
    }

    // MARK: - API 配置（多条，可增删改；当前选中的为生效配置）

    /// 全部 API 配置（持久化 JSON）。空时按默认提供商生成一条。
    var apiConfigs: [APIConfig] {
        get {
            guard let data = defaults.data(forKey: Key.apiConfigs),
                  let list = try? JSONDecoder().decode([APIConfig].self, from: data),
                  !list.isEmpty else {
                return [APIConfig(
                    id: "default", name: "默认",
                    provider: remoteProvider, model: llmModel,
                    baseURL: llmBaseURL, apiKey: llmAPIKey)]
            }
            return list
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            defaults.set(data, forKey: Key.apiConfigs)
        }
    }

    /// 当前生效的 API 配置 id（无则取第一条）。
    var activeAPIConfigID: String? {
        get { defaults.string(forKey: Key.activeAPIConfigID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.activeAPIConfigID)
            } else {
                defaults.removeObject(forKey: Key.activeAPIConfigID)
            }
        }
    }

    /// 当前生效的 API 配置（按 activeAPIConfigID 匹配，找不到取第一条）。
    var activeAPIConfig: APIConfig {
        let list = apiConfigs
        return list.first { $0.id == activeAPIConfigID } ?? list[0]
    }

    /// 添加或更新一条 API 配置；更新 activeID 指向它，并同步到当前生效字段。
    func upsertAPIConfig(_ config: APIConfig) {
        var list = apiConfigs
        if let i = list.firstIndex(where: { $0.id == config.id }) {
            list[i] = config
        } else {
            list.append(config)
        }
        apiConfigs = list
        activateAPIConfig(id: config.id)
    }

    /// 删除一条 API 配置；若删除的是当前生效项，切到第一条。
    func removeAPIConfig(id: String) {
        var list = apiConfigs
        list.removeAll { $0.id == id }
        apiConfigs = list
        if activeAPIConfigID == id {
            activeAPIConfigID = list.first?.id
            syncActiveToFields()
        }
    }

    /// 设置当前生效的 API 配置 id，并同步到远端字段（生成页共用）。
    func activateAPIConfig(id: String) {
        guard let config = apiConfigs.first(where: { $0.id == id }) else { return }
        activeAPIConfigID = id
        remoteProvider = config.provider
        llmModel = config.model
        llmBaseURL = config.baseURL
        llmAPIKey = config.apiKey
    }

    /// 把当前远端字段同步回 active 配置（生成页临时改后写回）。
    func syncActiveToFields() {
        let config = activeAPIConfig
        remoteProvider = config.provider
        llmModel = config.model
        llmBaseURL = config.baseURL
        llmAPIKey = config.apiKey
    }

    // MARK: - 工具

    /// 应用远端服务切换的默认值（地址/模型/Key 状态）。
    func applyProviderDefaults() {
        llmBaseURL = remoteProvider.defaultBaseURL
        llmModel = remoteProvider.defaultModel
        if !remoteProvider.needsAPIKey {
            llmAPIKey = ""
        }
    }

    /// 清除全部设置（测试用）。
    func reset() {
        for key in [Key.generatorTier, Key.remoteProvider, Key.llmModel,
                    Key.llmBaseURL, Key.llmAPIKey, Key.localModelPath,
                    Key.schedulerID, Key.embeddingVerification,
                    Key.contextWindow, Key.maxOutputTokens,
                    Key.defaultTargetCount, Key.defaultArticleLength,
                    Key.defaultWordFilter, Key.defaultRandomCount, Key.wordScoringID,
                    Key.appearanceMode,
                    Key.apiConfigs, Key.activeAPIConfigID,
                    Key.embeddingSource, Key.embeddingModel,
                    Key.useAgentSidecar, Key.useLocalAgentEnhancement,
                    Key.llamaServerBinaryPath, Key.llamaServerLifecycle] {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - API 配置类型

/// 一条远端 API 配置（服务名 + 提供商 + 模型 + 地址 + Key）。
/// @ai: 支持多条增删改；设置页下方独立管理区维护，上方默认配置区用菜单选择。
struct APIConfig: Identifiable, Codable, Equatable, Sendable {
    var id: String
    /// 显示名（如 "本地 Ollama" / "OpenAI 云端"）。
    var name: String
    var provider: RemoteProvider
    var model: String
    var baseURL: String
    var apiKey: String
    /// 模型是否思考型（nil=未探测，探测后写入；手动覆盖也是改此字段）。
    var isThinking: Bool? = nil
}

/// 思考型模型的思考 token 预算（与正文 max_tokens 独立，防思考挤占正文）。
/// @ai: DeepSeek V4 `thinking_budget`；Claude Extended Thinking `budget_tokens` 同语义。
enum ThinkingBudget {
    static let `default` = 2048
}

// MARK: - 设置枚举

/// 外观模式。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 词向量来源（RAG 选锚）。
enum EmbeddingSource: String, CaseIterable, Identifiable, Sendable {
    /// 内置 GloVe（30000 高频词 50 维，随 app 分发，零网络零命令行）。
    case builtinGloVe = "builtinGloVe"
    /// 远端 embeddings API（OpenAI 兼容端点，服务地址与 Key 复用远端 API 配置）。
    case remoteAPI = "remoteAPI"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .builtinGloVe: return "内置 GloVe"
        case .remoteAPI: return "远端 API"
        }
    }

    var help: String {
        switch self {
        case .builtinGloVe:
            return "随 app 分发的 3 万高频词向量，完全离线；生僻词自动用词库释义/LLM 兜底合成"
        case .remoteAPI:
            return "用远端 embedding 模型（如 Ollama nomic-embed-text）选锚，语义更准但依赖服务在线"
        }
    }
}
