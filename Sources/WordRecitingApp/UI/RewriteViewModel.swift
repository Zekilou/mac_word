import Foundation
import Observation

/// 改写 Tab 的 ViewModel：绑定源文 / 目标词输入，按 AppSettings 构造 LLM/远端生成器
/// 驱动 ContentGenSystem 落库，并加载生成历史。
/// @ai: 不再固定 RuleBasedGenerator——改写按「生成方式」设置走 LLM（mode .rewrite + sourceText），
///      LocalLLMGenerator 内部自带 RuleBasedGenerator 兜底（缺词用规则同义替换）；纯规则档仍可通过注入 generator 复用。
/// @ai: UI 不写 SQL；所有写入通过 World.run(ContentGenSystem)；图查询走 GraphQueries。
@MainActor
@Observable
final class RewriteViewModel {

    // MARK: - 输入

    var sourceText: String = ""
    var targetsText: String = ""

    // MARK: - 输出

    var isGenerating: Bool = false
    var errorMessage: String?
    var resultArticle: GeneratedArticle?
    var history: [ArticleHistoryItem] = []
    var selectedArticle: StoredArticle?
    /// 生成阶段（进度展示）。
    var genStage: GenStage?

    // MARK: - 依赖（常量，不参与观察）

    let world: World
    /// 应用设置（UserDefaults）：启动读入、生成前写回。
    let settings: AppSettings
    /// 显式注入的生成器（测试 / 外部回退用）；nil = 运行时按 settings 自动构造。
    let injectedGenerator: (any ContentGenerator)?
    let constraints: GenerationConstraints = GenerationConstraints()

    // MARK: - 生成方式（按 AppSettings 读入，UI 可切换并写回）

    /// 生成器档位：进程内本地 / 远端 LLM。
    var generatorTier: GeneratorTier = .remote
    /// 远端服务类型：Ollama（本机 / 局域网）或 OpenAI API（云端）。
    var remoteProvider: RemoteProvider = .ollama
    /// 远端 LLM 配置（切换 remoteProvider 时重置为默认值）。
    var llmModel: String = RemoteProvider.ollama.defaultModel
    var llmBaseURL: String = RemoteProvider.ollama.defaultBaseURL
    var llmAPIKey: String = ""

    /// API 配置列表（转发 AppSettings）。
    var apiConfigs: [APIConfig] {
        get { settings.apiConfigs }
        set { settings.apiConfigs = newValue }
    }

    /// 当前生效的 API 配置 id。
    var activeAPIConfigID: String? {
        get { settings.activeAPIConfigID }
        set { settings.activeAPIConfigID = newValue }
    }

    /// 当前生效配置是否思考型模型（探测结果；nil=未探测）。
    var activeConfigIsThinking: Bool? {
        settings.activeAPIConfig.isThinking
    }

    init(
        world: World,
        settings: AppSettings = .shared,
        generator: (any ContentGenerator)? = nil
    ) {
        self.world = world
        self.settings = settings
        self.injectedGenerator = generator
        // 启动时从设置读入
        generatorTier = settings.generatorTier
        let active = settings.activeAPIConfig
        remoteProvider = active.provider
        llmModel = active.model
        llmBaseURL = active.baseURL
        llmAPIKey = active.apiKey
    }

    /// 把当前生成配置写回 AppSettings（生成前调用，保证设置页与改写页一致）。
    func persistSettings() {
        settings.generatorTier = generatorTier
        settings.remoteProvider = remoteProvider
        settings.llmModel = llmModel
        settings.llmBaseURL = llmBaseURL
        settings.llmAPIKey = llmAPIKey
    }

    /// 应用选中的 API 配置：同步到本地字段 + 设置生效项。
    func applyAPIConfig(_ config: APIConfig) {
        settings.activateAPIConfig(id: config.id)
        remoteProvider = config.provider
        llmModel = config.model
        llmBaseURL = config.baseURL
        llmAPIKey = config.apiKey
    }

    // MARK: - 构造生成器

    /// 按当前档位构造生成器。显式注入时直接返回（测试 / 外部回退）。
    /// @ai: 复用 GenerateViewModel.makeGenerator() 模式——进程内档用 LlamaCPPClient、
    ///      远端档用 OpenAICompatibleClient，外面包 LocalLLMGenerator（mode .rewrite + sourceText
    ///      走 LLM 改写，内部自带 RuleBasedGenerator 兜底缺词）；可选 AgentSidecarGenerator 接管。
    func makeGenerator() throws -> any ContentGenerator {
        if let injectedGenerator { return injectedGenerator }
        let embeddingProvider: EmbeddingProvider? = makeEmbeddingProvider()
        switch generatorTier {
        case .processLocal:
            guard let path = settings.localModelPath, !path.isEmpty else {
                throw GenerateError.engineUnavailable(
                    "请先在「设置」→「进程内模型」选择 GGUF 模型文件（可导入或从 Ollama 提取）。")
            }
            let fallback = LocalLLMGenerator(
                client: LlamaCPPClient(modelPath: path),
                contextWindow: settings.contextWindow,
                outputTokenLimit: settings.maxOutputTokens > 0 ? settings.maxOutputTokens : nil,
                onProgress: progressHandler,
                embeddingProvider: embeddingProvider)
            // 本地 agent 增强：启用 + llama-server 运行中 + sidecar 可定位 → 接管，回退 LocalLLMGenerator。
            if settings.useLocalAgentEnhancement,
               let baseURL = LlamaServerProcess.shared.baseURL,
               let (exec, script) = AgentSidecarLocator.resolve() {
                let spec = AgentSidecarModelSpec(
                    model: URL(fileURLWithPath: path).lastPathComponent,
                    baseURL: baseURL,
                    apiKey: "",
                    isThinking: false,
                    contextWindow: settings.contextWindow,
                    temperature: 0.7)
                return AgentSidecarGenerator(
                    client: AgentSidecarClient(executable: exec, scriptPath: script),
                    spec: spec,
                    onProgress: progressHandler,
                    fallback: fallback)
            }
            return fallback
        case .remote:
            let isThinking = settings.activeAPIConfig.isThinking ?? false
            let client = OpenAICompatibleClient(
                baseURL: llmBaseURL,
                apiKey: llmAPIKey.isEmpty ? nil : llmAPIKey,
                model: llmModel,
                isThinking: isThinking)
            let fallback = LocalLLMGenerator(
                client: client,
                contextWindow: settings.contextWindow,
                outputTokenLimit: settings.maxOutputTokens > 0 ? settings.maxOutputTokens : nil,
                onProgress: progressHandler, isThinking: isThinking,
                embeddingProvider: embeddingProvider)
            // Agent sidecar 开启且可定位时接管远端管线；不可用/出错自动回退 fallback。
            if settings.useAgentSidecar, let (exec, script) = AgentSidecarLocator.resolve() {
                let spec = AgentSidecarModelSpec(
                    model: llmModel, baseURL: llmBaseURL, apiKey: llmAPIKey,
                    isThinking: isThinking,
                    contextWindow: settings.contextWindow,
                    temperature: 0.7)
                return AgentSidecarGenerator(
                    client: AgentSidecarClient(executable: exec, scriptPath: script),
                    spec: spec,
                    onProgress: progressHandler,
                    fallback: fallback)
            }
            return fallback
        }
    }

    /// 按「词向量来源」设置构造词向量提供者（改写模式暂未启用，保留与造文一致）。
    private func makeEmbeddingProvider() -> EmbeddingProvider? {
        switch settings.embeddingSource {
        case .builtinGloVe:
            return GloVeEmbeddingProvider()
        case .remoteAPI:
            let config = settings.activeAPIConfig
            return RemoteEmbeddingProvider(
                baseURL: config.baseURL,
                apiKey: config.apiKey.isEmpty ? nil : config.apiKey,
                model: settings.embeddingModel)
        }
    }

    /// 进度回调：阶段切换 → 切回主线程更新 UI（改写只有 generating / polishing 阶段）。
    private var progressHandler: @Sendable (GenProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                if case .stage(let stage) = progress {
                    self?.genStage = stage
                }
            }
        }
    }

    // MARK: - 目标词解析

    /// 把 "A,B;C\nD" 解析为 [A,B,C,D]：按逗号 / 分号 / 换行 / 制表符切分，
    /// 去首尾空白，大小写不敏感去重，保留首次出现的大小写。
    /// 纯函数，不依赖实例状态 → nonisolated，任意上下文可调用。
    nonisolated static func parseTargets(_ text: String) -> [String] {
        let separators: Set<Character> = [",", ";", "\n", "\r", "\t"]
        var seen = Set<String>()
        var result: [String] = []
        var current = ""
        for ch in text {
            if separators.contains(ch) {
                flush(&current, into: &seen, result: &result)
            } else {
                current.append(ch)
            }
        }
        flush(&current, into: &seen, result: &result)
        return result
    }

    nonisolated private static func flush(
        _ current: inout String, into seen: inout Set<String>, result: inout [String]
    ) {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted {
            result.append(trimmed)
        }
        current = ""
    }

    // MARK: - 改写

    /// 跑一次快速改写：解析目标词 → 解析为 lemma id → 按当前生成方式构造生成器 → 生成 → 单事务落库 → 刷新历史。
    func runRewrite() async {
        isGenerating = true
        errorMessage = nil
        selectedArticle = nil
        genStage = nil
        defer { isGenerating = false }
        do {
            persistSettings()
            let targets = Self.parseTargets(targetsText)
            let targetIds = try resolveTargetIds(targets)
            let source = sourceText.isEmpty ? nil : sourceText
            let generator = try makeGenerator()
            let article = try await generator.generate(
                mode: .rewrite,
                sourceText: source,
                targetLemmas: targetIds,
                constraints: constraints,
                graph: world.graph)
            try world.run(ContentGenSystem(), context: ContentGenContext(
                article: article, targetLemmas: targetIds,
                sourceText: source, topic: nil))
            resultArticle = article
            genStage = nil
            loadHistory()
        } catch {
            errorMessage = "\(error)"
            genStage = nil
        }
    }

    /// 把目标词文本逐个映射到 Lemma EntityID（findLemmaId 大小写不敏感）。
    /// 未匹配的目标词静默跳过。
    private func resolveTargetIds(_ targets: [String]) throws -> [EntityID] {
        var ids: [EntityID] = []
        for t in targets {
            if let id = try world.graph.findLemmaId(byTextA: t.lowercased()) {
                ids.append(id)
            }
        }
        return ids
    }

    // MARK: - 历史

    /// 刷新最近 20 条改写历史。
    func loadHistory() {
        do {
            history = try world.graph.recentArticles(mode: .rewrite, limit: 20)
        } catch {
            history = []
        }
    }

    /// 选中一条历史 → 加载完整 Article 回看。
    func selectHistory(_ id: EntityID) {
        resultArticle = nil
        do {
            selectedArticle = try world.graph.loadArticle(id: id)
        } catch {
            selectedArticle = nil
        }
    }
}
