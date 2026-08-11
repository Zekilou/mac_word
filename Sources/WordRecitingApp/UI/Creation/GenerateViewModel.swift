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

    // MARK: - 输出

    var isGenerating = false
    var errorMessage: String?
    var resultArticle: GeneratedArticle?
    /// 生成阶段（进度展示）。
    var genStage: GenStage?
    /// 实时流式输出缓冲（生成中显示在内容栏，打字机效果）。
    var streamedText: String = ""
    var history: [ArticleHistoryItem] = []
    var selectedArticle: StoredArticle?
    /// 本次阅读会话中已标记过的目标词（lemmaId 集合，用于 UI 绿色反馈）。
    var ratedLemmaIds: Set<EntityID> = []

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

    /// 切换远端服务类型时应用该服务的默认地址/模型/Key 状态。
    func applyProviderDefaults() {
        llmBaseURL = remoteProvider.defaultBaseURL
        llmModel = remoteProvider.defaultModel
        if !remoteProvider.needsAPIKey {
            llmAPIKey = ""
        }
    }

    init(world: World, settings: AppSettings = .shared) {
        self.world = world
        self.settings = settings
        // 启动时从设置读入
        generatorTier = settings.generatorTier
        remoteProvider = settings.remoteProvider
        llmModel = settings.llmModel
        llmBaseURL = settings.llmBaseURL
        llmAPIKey = settings.llmAPIKey
    }

    /// 把当前生成配置写回 AppSettings（生成前调用，保证设置页与生成页一致）。
    func persistSettings() {
        settings.generatorTier = generatorTier
        settings.remoteProvider = remoteProvider
        settings.llmModel = llmModel
        settings.llmBaseURL = llmBaseURL
        settings.llmAPIKey = llmAPIKey
    }

    /// 本次生成在全局活动中心的注册 id（进程守护显示用）。
    private var activityID: UUID?

    /// 本次生成的写作计划（规划 pass 产出，展示思考过程）。
    var lastPlan: String?
    /// 本次生成的策略决策（策略 pass 产出，展示思考链）。
    var lastStrategy: GenStrategy?
    /// 目标词覆盖统计：每个目标词是否成功嵌入正文。
    var coverage: [WordCoverage] = []

    /// 进度回调：阶段切换 + 流式 token → 切回主线程更新 UI。
    private var progressHandler: @Sendable (GenProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch progress {
                case .stage(let stage):
                    self.genStage = stage
                    if let id = self.activityID {
                        let p: Double
                        let msg: String
                        switch stage {
                        case .strategy: p = 0.05; msg = "正在制定生成策略…"
                        case .planning: p = 0.15; msg = "正在联想打草稿…"
                        case .generating: p = 0.4; msg = "正在生成正文…"
                        case .embedding: p = 0.55; msg = "正在逐词融入…"
                        case .polishing: p = 0.75; msg = "正在改写润色…"
                        case .saving: p = 0.95; msg = "正在保存…"
                        }
                        GlobalActivityCenter.shared.update(id, progress: p, message: msg)
                    }
                case .token(let text):
                    self.streamedText += text
                case .word:
                    // 逐词融入进度：后续任务接入 embedWordProgress 展示
                    break
                }
            }
        }
    }

    /// 按当前档位构造生成器。
    /// @ai: 进程内档用 LlamaCPPClient（swift-llama-cpp 的 llama.cpp 引擎），需先在设置选择模型文件。
    func makeGenerator() throws -> any ContentGenerator {
        switch generatorTier {
        case .processLocal:
            guard let path = settings.localModelPath, !path.isEmpty else {
                throw GenerateError.engineUnavailable(
                    "请先在「设置」→「进程内模型」选择 GGUF 模型文件（可导入或从 Ollama 提取）。")
            }
            return LocalLLMGenerator(
                client: LlamaCPPClient(modelPath: path), onProgress: progressHandler)
        case .remote:
            let client = OpenAICompatibleClient(
                baseURL: llmBaseURL,
                apiKey: llmAPIKey.isEmpty ? nil : llmAPIKey,
                model: llmModel)
            return LocalLLMGenerator(client: client, onProgress: progressHandler)
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

    /// 从当前词库按筛选条件随机选 randomCount 个词，并入已选集合（不重复）。
    /// @ai: 纯内存操作，不写库；随机性由 shuffle 提供。
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
        let count = max(1, randomCount)
        let picked = pool.shuffled().prefix(count).map(\.lemmaId)
        pickedLemmaIds.formUnion(picked)
        return Array(picked)
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
        do {
            persistSettings()
            let targetIds = try resolveTargets()
            guard !targetIds.isEmpty else {
                errorMessage = "请至少选择一个目标词（从词库勾选或手动输入）"
                isGenerating = false
                return
            }
            let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty else {
                errorMessage = "请输入文章主题（如：科技趋势、环保）"
                isGenerating = false
                return
            }
            var c = constraints
            c.topic = topic
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
                    try world.run(ContentGenSystem(), context: ContentGenContext(
                        article: article, targetLemmas: targetIds,
                        sourceText: topic, topic: topic, mode: .generate))
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.resultArticle = article
                        self.lastPlan = article.plan
                        self.lastStrategy = article.strategy
                        self.coverage = Self.computeCoverage(
                            article: article, targetIds: targetIds, graph: world.graph)
                        self.genStage = nil
                        self.streamedText = ""
                        self.isGenerating = false
                        self.loadHistory()
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.errorMessage = "\(error)"
                        self?.isGenerating = false
                    }
                }
            }
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
}

/// 生成结果中单个目标词的命中状态。
struct WordCoverage: Identifiable, Equatable, Sendable {
    let word: String
    let hit: Bool
    var id: String { word }
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
