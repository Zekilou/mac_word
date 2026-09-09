import Foundation
import Observation

/// 造文（主路径）ViewModel：主题 + 目标词（从词库勾选或手动输入）→ 生成文章 → 落库 → 历史。
/// @ai: UI 不写 SQL；生成走 ContentGenerator；落库走 World.run(ContentGenSystem)。
@MainActor
@Observable
final class GenerateViewModel {

    // MARK: - 输入

    var topic: String = ""
    /// 手动输入目标词（逗号/换行分隔）——兜底路径。
    var targetsText: String = ""
    /// 从词库勾选的目标词（lemmaId 集合）。
    var pickedLemmaIds: Set<EntityID> = []

    // MARK: - 词库数据（选词面板）

    var decks: [DeckSummary] = []
    var selectedDeckId: EntityID?
    var deckCards: [CardListItem] = []
    /// 随机选词范围筛选（学过 / 未学过 / 全部）。
    var wordFilter: WordFilter = .all
    /// 随机选词数量。
    var randomCount: Int = 10
    /// 选词打分策略（默认随机，与升级前一致）。
    var wordScoringID: WordScoringID = .random

    // MARK: - 输出

    var isGenerating = false
    var errorMessage: String?
    var resultArticle: GeneratedArticle?
    /// 生成阶段（进度展示）。
    var genStage: GenStage?
    /// 实时流式输出缓冲（生成中显示在内容栏，打字机效果）。
    var streamedText: String = ""
    /// 本次生成目标词的表面形式（runGenerate 时固定，供流式正文实时高亮）。
    var liveSurfaces: [EntityID: String] = [:]
    var history: [ArticleHistoryItem] = []
    var selectedArticle: StoredArticle?
    /// 本次阅读会话中已标记过的目标词（lemmaId 集合，用于 UI 绿色反馈）。
    var ratedLemmaIds: Set<EntityID> = []

    // MARK: - 文章全词状态（阅读区词块）

    /// 当前阅读文章的词列表（词块布局；目标词 isTarget=true 走复习评分交互，其余走全局掌握度）。
    var articleWords: [ArticleWordToken] = []
    /// 会话内点击覆盖状态（lemma → 会不会）；未点过的词跟随全局记录。
    var sessionWordStates: [String: Bool] = [:]
    /// 全局掌握度（lemma → mastery）：已记录词直接标色。
    var masteryByLemma: [String: Double] = [:]
    /// 出现过次数（lemma → seen_count）。
    var seenByLemma: [String: Int] = [:]
    /// BKT 后验概率（lemma → 概率）：判定主口径。
    var beliefByLemma: [String: Double] = [:]
    /// 已加载文章的 body 标识（ensureArticleWords 守卫：body 相同则零副作用返回，防重绘重入/每帧 SQL）。
    var loadedBodyKey: String?
    /// 词形 → lemmaId 缓存（预解析一次，渲染路径零 SQL；articleMarkState 惰性兜底）。
    var lemmaIdByWord: [String: EntityID] = [:]

    // MARK: - 依赖

    let world: World
    /// 应用设置（UserDefaults）：启动读入、生成前写回。
    let settings: AppSettings
    /// 生成器档位：进程内本地（待接入）/ 远端 LLM（Ollama 或 OpenAI API）。
    /// @ai: 已按用户要求移除纯规则档（模板拼装不可读）；Ollama 视为远端。
    var generatorTier: GeneratorTier = .remote
    /// 远端服务类型：Ollama（本机 / 局域网）或 OpenAI API（云端）。
    var remoteProvider: RemoteProvider = .ollama
    /// 远端 LLM 配置（切换 remoteProvider 时重置为该服务的默认值）。
    var llmModel: String = RemoteProvider.ollama.defaultModel
    var llmBaseURL: String = RemoteProvider.ollama.defaultBaseURL
    var llmAPIKey: String = ""
    let constraints: GenerationConstraints = GenerationConstraints()

    /// API 配置列表（转发 AppSettings；增删改在设置页「API 配置」区）。
    var apiConfigs: [APIConfig] {
        get { settings.apiConfigs }
        set { settings.apiConfigs = newValue }
    }

    /// 当前生效的 API 配置 id。
    var activeAPIConfigID: String? {
        get { settings.activeAPIConfigID }
        set { settings.activeAPIConfigID = newValue }
    }

    /// 切换远端服务类型时应用该服务的默认地址/模型/Key 状态。
    func applyProviderDefaults() {
        llmBaseURL = remoteProvider.defaultBaseURL
        llmModel = remoteProvider.defaultModel
        if !remoteProvider.needsAPIKey {
            llmAPIKey = ""
        }
    }

    /// 应用选中的 API 配置：同步到本地字段 + 设置生效项。
    /// @ai: 设置页与创作页共用组件后，创作页切换配置走这里（生成前 persistSettings 写回）。
    func applyAPIConfig(_ config: APIConfig) {
        settings.activateAPIConfig(id: config.id)
        remoteProvider = config.provider
        llmModel = config.model
        llmBaseURL = config.baseURL
        llmAPIKey = config.apiKey
        // 配置发生改变 → 触发联通性 + 模型类型探测（异步，不阻塞 UI）
        probeActiveConfig()
    }

    /// 当前生效配置是否思考型模型（探测结果；nil=未探测）。
    var activeConfigIsThinking: Bool? {
        settings.activeAPIConfig.isThinking
    }

    /// 联通性 + 模型类型探测（配置变更时触发）。
    /// @ai: 探测结果写回 APIConfig.isThinking（设置页可手动覆盖）；失败不打断生成（保守按普通型）。
    func probeActiveConfig() {
        guard generatorTier == .remote else { return }
        let client = OpenAICompatibleClient(
            baseURL: llmBaseURL,
            apiKey: llmAPIKey.isEmpty ? nil : llmAPIKey,
            model: llmModel)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await client.probe()
            guard result.reachable else { return }  // 联通失败：保留原判定，不打断
            var config = self.settings.activeAPIConfig
            config.isThinking = result.isThinking
            self.settings.upsertAPIConfig(config)
        }
    }

    init(world: World, settings: AppSettings = .shared) {
        self.world = world
        self.settings = settings
        // 启动时从设置读入
        generatorTier = settings.generatorTier
        wordScoringID = settings.wordScoringID
        let active = settings.activeAPIConfig
        remoteProvider = active.provider
        llmModel = active.model
        llmBaseURL = active.baseURL
        llmAPIKey = active.apiKey
    }

    /// 把当前生成配置写回 AppSettings（生成前调用，保证设置页与生成页一致）。
    func persistSettings() {
        settings.generatorTier = generatorTier
        settings.remoteProvider = remoteProvider
        settings.llmModel = llmModel
        settings.llmBaseURL = llmBaseURL
        settings.llmAPIKey = llmAPIKey
        settings.wordScoringID = wordScoringID
    }

    /// 本次生成在全局活动中心的注册 id（进程守护显示用）。
    private var activityID: UUID?
    /// 本次生成开始时间（日志条目耗时基准）。
    private var genStartedAt: Date?
    /// 当前流式阶段开始时间。
    private var phaseStartAt: Date?
    /// 是否已收到首个正文 token。
    private var firstTokenSeen = false

    /// 本次生成的写作计划（规划 pass 产出，展示思考过程）。
    var lastPlan: String?
    /// 本次生成的策略决策（策略 pass 产出，展示思考链）。
    var lastStrategy: GenStrategy?
    /// 目标词覆盖统计：每个目标词是否成功嵌入正文。
    var coverage: [WordCoverage] = []
    /// 逐词融入进度（generate-rewrite 时实时更新）。
    var embedWordProgress: EmbedWordProgress?
    /// 未能自然融入的目标词（结构化报告，UI 覆盖 ✗ chip 悬停显示原因）。
    var lastSkipped: [SkippedWord] = []
    /// 思考日志（生成过程中实时累积，路由到左侧进度区）。
    var thinkingLog: [ThinkingLogItem] = []
    /// 模型自报的当前阶段（来自 THINKING 标记行；无则回退管线阶段）。
    var modelStage: String?
    /// 当前流式阶段指标（首 token/速率/token 数）。
    var streamStats = StreamStats()

    /// 流式正文的目标词 spans（随 streamedText 增长实时重算，阅读区生成中即高亮）。
    var liveSpans: [SpanInfo] {
        LocalLLMGenerator.findTargetSpans(body: streamedText, surfaces: liveSurfaces)
    }

    /// 进度回调：阶段切换 + 流式 token + 逐词进度 → 切回主线程更新 UI。
    private var progressHandler: @Sendable (GenProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.applyProgress(progress)
            }
        }
    }

    /// 应用一次进度事件（主线程；progressHandler 与测试共用）。
    func applyProgress(_ progress: GenProgress) {
        switch progress {
        case .stage(let stage):
            genStage = stage
            if stage == .generating || stage == .polishing {
                phaseStartAt = Date()
                firstTokenSeen = false
                streamStats = StreamStats()
            }
            if stage == .polishing {
                // 自查输出即最终正文：从头流式展示，防「草稿 + 自查全文」拼接
                streamedText = ""
            }
            if let id = activityID {
                let p: Double
                let msg: String
                switch stage {
                case .strategy: p = 0.05; msg = "正在制定生成策略…"
                case .planning: p = 0.15; msg = "正在联想打草稿…"
                case .generating: p = 0.4; msg = "正在生成正文…"
                case .embedding: p = 0.55; msg = "正在逐词融入…"
                case .polishing: p = 0.8; msg = "正在改写润色…"
                case .saving: p = 0.95; msg = "正在保存…"
                }
                GlobalActivityCenter.shared.update(id, progress: p, message: msg)
            }
        case .token(let text):
            streamedText += text
            // 实时展示兜底：剥离独立标记行（防变体标记闪进流式视图）
            streamedText = AgenticPrompts.strippingMarkerLines(streamedText)
            let now = Date()
            if phaseStartAt == nil { phaseStartAt = now }
            if !firstTokenSeen {
                firstTokenSeen = true
                streamStats.firstTokenLatency = now.timeIntervalSince(phaseStartAt!)
            }
            streamStats.tokens += 1
            let elapsed = now.timeIntervalSince(phaseStartAt!)
            if elapsed > 0 { streamStats.rate = Double(streamStats.tokens) / elapsed }
        case .word(let done, let total, let word):
            embedWordProgress = EmbedWordProgress(done: done, total: total, word: word)
        case .thought(let thought):
            // 模型 THINKING 自报行 → 当前阶段（模型自己标记；顶部全局状态条同步）
            if thought.id.hasPrefix("model-"), thought.message.hasPrefix("模型：") {
                let t = String(thought.message.dropFirst("模型：".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                modelStage = t.isEmpty ? nil : t
                if let id = activityID, let stage = modelStage {
                    GlobalActivityCenter.shared.update(id, message: "模型：\(stage)")
                }
            }
            let elapsed = Date().timeIntervalSince(genStartedAt ?? Date())
            if let idx = thinkingLog.firstIndex(where: { $0.id == thought.id }) {
                thinkingLog[idx] = ThinkingLogItem(
                    id: thought.id, kind: thought.kind, message: thought.message,
                    detail: thought.detail, status: thought.status,
                    elapsedAt: thinkingLog[idx].elapsedAt)
            } else {
                thinkingLog.append(ThinkingLogItem(
                    id: thought.id, kind: thought.kind, message: thought.message,
                    detail: thought.detail, status: thought.status, elapsedAt: elapsed))
            }
        }
    }

    /// 按当前档位构造生成器。
    /// @ai: 进程内档用 LlamaCPPClient（swift-llama-cpp 的 llama.cpp 引擎），需先在设置选择模型文件。
    ///      进程内档 + 启用「本地 agent 增强」+ llama-server 运行中 → 改走 sidecar（回退 LocalLLMGenerator）。
    ///      embeddingProvider：按「词向量来源」设置构造（内置 GloVe / 远端 API）；查询失败自动回退 LLM 联想。
    func makeGenerator() throws -> any ContentGenerator {
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
            // @ai: 与远端 useAgentSidecar 互不干扰；model 名用 gguf 文件名（llama-server 接受任意名）。
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
            // Agent sidecar 开启且可定位时接管远端管线；不可用/出错自动回退 fallback（LocalLLMGenerator）。
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

    /// 按「词向量来源」设置构造词向量提供者。
    /// @ai: 内置 GloVe 未随包分发时返回 nil（管线回退 LLM 联想）；远端用 activeAPIConfig 的地址/Key。
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

    // MARK: - 数据加载

    /// 加载所有 deck。
    func loadDecks() {
        do {
            decks = try world.graph.allDecks()
        } catch {
            decks = []
            errorMessage = "\(error)"
        }
    }

    /// 选择 deck → 加载其卡片列表。
    func selectDeck(_ deckId: EntityID) {
        selectedDeckId = deckId
        deckCards = []
        do {
            deckCards = try world.graph.cardsInDeck(deckId)
        } catch {
            deckCards = []
            errorMessage = "\(error)"
        }
    }

    /// 已选目标词的表面形式（供 UI 展示标签）。
    var pickedWords: [String] {
        do {
            return try world.graph.lemmaSurfaces(for: Array(pickedLemmaIds))
                .values.sorted()
        } catch {
            return []
        }
    }

    // MARK: - 随机选词

    /// 从当前词库按筛选条件选 randomCount 个词（按选词策略打分），并入已选集合（不重复）。
    /// @ai: WordFilter 仍是预过滤（全部/未学过/学过）；打分交给 WordScoringStrategy。
    @discardableResult
    func randomPick() -> [EntityID] {
        guard selectedDeckId != nil else { return [] }
        let pool = deckCards.filter { card in
            switch wordFilter {
            case .all: return true
            case .unlearned: return (card.reps ?? 0) == 0
            case .learned: return (card.reps ?? 0) > 0
            }
        }
        guard !pool.isEmpty else { return [] }

        let features: [WordFeatures]
        do {
            let byId = try world.graph.wordFeatures(lemmaIds: pool.map(\.lemmaId))
            features = pool.compactMap { byId[$0.lemmaId] }
        } catch {
            errorMessage = "读取词元特征失败：\(error)"
            return []
        }

        let picked = WordSelector.top(
            max(1, randomCount),
            from: features,
            strategy: SchedulingRegistry.scoring(wordScoringID),
            context: ScoringContext(purpose: .articleTargets,
                                    now: Date(), bandWindow: nil))
        pickedLemmaIds.formUnion(picked)
        return picked
    }

    /// 解析最终目标词列表：勾选集合 ∪ 手动输入。
    func resolveTargets() throws -> [EntityID] {
        var ids = Array(pickedLemmaIds)
        let manual = RewriteViewModel.parseTargets(targetsText)
        for m in manual {
            if let id = try world.graph.findLemmaId(byTextA: m.lowercased()) {
                ids.append(id)
            }
        }
        // 保序去重
        var seen = Set<EntityID>()
        var result: [EntityID] = []
        for id in ids where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    // MARK: - 生成

    /// 计算目标词覆盖：命中 = 正文 spans 含该 lemmaId。
    /// @ai: 纯只读查询；供生成结果展示"哪些词成功加入、哪些没有"。
    nonisolated static func computeCoverage(
        article: GeneratedArticle, targetIds: [EntityID], graph: GraphQueries
    ) -> [WordCoverage] {
        let hitIds = Set(article.spans.compactMap { $0.lemmaId })
        let surfaces = (try? graph.lemmaSurfaces(for: targetIds)) ?? [:]
        return targetIds.map { id in
            WordCoverage(word: surfaces[id] ?? "?", hit: hitIds.contains(id))
        }
    }

    /// 跑一次快速造文：主题 + 目标词 → 生成（流式进度）→ 单事务落库 → 刷新历史。
    /// 生成任务托管到全局活动中心执行，切页/销毁 View 不中断；完成后自动落库。
    func runGenerate() {
        isGenerating = true
        errorMessage = nil
        selectedArticle = nil
        genStage = nil
        streamedText = ""
        lastPlan = nil
        lastStrategy = nil
        coverage = []
        embedWordProgress = nil
        lastSkipped = []
        thinkingLog = []
        modelStage = nil
        liveSurfaces = [:]
        streamStats = StreamStats()
        genStartedAt = Date()
        phaseStartAt = nil
        firstTokenSeen = false
        do {
            persistSettings()
            let targetIds = try resolveTargets()
            liveSurfaces = (try? world.graph.lemmaSurfaces(for: targetIds)) ?? [:]
            guard !targetIds.isEmpty else {
                errorMessage = "请至少选择一个目标词（从词库勾选或手动输入）"
                isGenerating = false
                return
            }
            let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            // 主题可留空：空主题时模型围绕目标词本身成文（词驱动），嵌入成功率更高
            var c = constraints
            c.topic = topic
            c.embeddingVerification = settings.embeddingVerification
            let consts = c
            let generator = try makeGenerator()
            let world = self.world
            let id = GlobalActivityCenter.shared.begin(
                title: "生成文章", icon: "sparkles", progress: 0.0, message: "准备中…")
            activityID = id
            GlobalActivityCenter.shared.run(id) {
                do {
                    let article = try await generator.generate(
                        mode: .generate,
                        sourceText: topic,
                        targetLemmas: targetIds,
                        constraints: consts,
                        graph: world.graph)
                    guard !article.body.isEmpty else {
                        await MainActor.run { [weak self] in
                            self?.errorMessage = "生成结果为空，请检查目标词是否存在于词库"
                            self?.isGenerating = false
                        }
                        return
                    }
                    await MainActor.run { [weak self] in
                        self?.applyProgress(.thought(GenThought(
                            id: "save", kind: .saving,
                            message: "正在保存…", detail: nil, status: .running)))
                    }
                    try world.run(ContentGenSystem(), context: ContentGenContext(
                        article: article, targetLemmas: targetIds,
                        sourceText: topic, topic: topic, mode: .generate))
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.resultArticle = article
                        self.lastPlan = article.plan
                        self.lastStrategy = article.strategy
                        self.lastSkipped = article.skippedWords
                        self.coverage = Self.computeCoverage(
                            article: article, targetIds: targetIds, graph: world.graph)
                        self.applyProgress(.thought(GenThought(
                            id: "save", kind: .saving,
                            message: "保存完成", detail: nil, status: .done)))
                        self.genStage = nil
                        self.streamedText = ""
                        self.isGenerating = false
                        self.loadHistory()
                    }
                } catch is CancellationError {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.isGenerating = false
                        self.applyProgress(.thought(GenThought(
                            id: "info", kind: .info,
                            message: "已取消", detail: nil, status: .done)))
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.errorMessage = "\(error)"
                        self?.isGenerating = false
                    }
                }
            }
        } catch is CancellationError {
            isGenerating = false
            applyProgress(.thought(GenThought(
                id: "info", kind: .info,
                message: "已取消", detail: nil, status: .done)))
        } catch {
            errorMessage = "\(error)"
            isGenerating = false
        }
    }

    // MARK: - 历史

    func loadHistory() {
        do {
            history = try world.graph.recentArticles(mode: .generate, limit: 20)
        } catch {
            history = []
        }
    }

    func selectHistory(_ id: EntityID) {
        resultArticle = nil
        do {
            selectedArticle = try world.graph.loadArticle(id: id)
        } catch {
            selectedArticle = nil
        }
    }

    // MARK: - 阅读标记（驱动复习调度）

    /// 阅读点击目标词：反查其卡片（供释义展示与评分）。
    func cardForReading(_ lemmaId: EntityID) -> CardListItem? {
        try? world.graph.cardForLemma(lemmaId)
    }

    /// 标记目标词：认识(good) / 不认识(again)。走 World.run(StudySystem) 调度。
    @discardableResult
    func markReadingWord(lemmaId: EntityID, rating: Rating) -> Bool {
        guard let card = cardForReading(lemmaId) else { return false }
        do {
            try world.run(StudySystem(), context: StudySystem.StudyOp(
                cardId: card.cardId, rating: rating, reviewedAt: Date()))
            ratedLemmaIds.insert(lemmaId)
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// 覆盖 ✗ chip 的悬停原因（来自跳过词结构化报告）。
    func skippedReason(for word: String) -> String? {
        lastSkipped.first { $0.word == word }?.reason
    }

    /// 停止当前生成（取消全局活动中心任务；步间生效）。
    func stopGenerating() {
        guard let id = activityID, isGenerating else { return }
        GlobalActivityCenter.shared.cancel(id)
    }

    // MARK: - 当前模型参数信息（生成方式列底部展示）

    /// 当前模型的可展示参数（名称 / 参数量 / 上下文窗口 / 采样参数）。
    /// @ai: 与设置页共用 GenerationConfigSection.makeParameters，保证两处一致。
    var modelParameters: [ModelParameter] {
        GenerationConfigSection.makeParameters(
            tier: generatorTier, model: llmModel,
            localPath: settings.localModelPath, maxWords: constraints.maxWords,
            contextWindow: settings.contextWindow,
            outputTokenLimit: settings.maxOutputTokens > 0 ? settings.maxOutputTokens : nil)
    }
}

/// 思考日志条目（VM 侧，按生成器 thought 事件 upsert）。
struct ThinkingLogItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: GenThought.Kind
    var message: String
    var detail: String?
    var status: GenThought.Status
    let elapsedAt: TimeInterval
}

/// 流式阶段实时指标。
struct StreamStats: Equatable, Sendable {
    var firstTokenLatency: TimeInterval?
    var tokens: Int = 0
    var rate: Double = 0
}

/// 逐词融入进度（供进度条下方显示「3/10 battle」）。
struct EmbedWordProgress: Equatable, Sendable {
    let done: Int
    let total: Int
    let word: String
}

/// 生成结果中单个目标词的命中状态。
struct WordCoverage: Identifiable, Equatable, Sendable {
    let word: String
    let hit: Bool
    var id: String { word }
}

/// 当前模型的可展示参数行（生成方式列底部信息卡）。
struct ModelParameter: Identifiable, Sendable {
    let label: String
    let value: String
    let help: String
    var id: String { label }
}

/// 生成器构造错误（不落库，仅 UI 提示）。
enum GenerateError: LocalizedError, Sendable {
    /// 进程内本地引擎尚未接入。
    case engineUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let msg):
            return msg
        }
    }
}

/// 随机选词的范围筛选：按卡片是否复习过（reps > 0 = 学过）过滤。
enum WordFilter: String, CaseIterable, Identifiable, Sendable {
    case all, unlearned, learned
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .unlearned: return "未学过"
        case .learned: return "学过"
        }
    }
}
