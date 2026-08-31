import Foundation
import Observation

/// 词汇初始化 ViewModel：LLM 生成易读段落 → 用户标不会 → 批量写全局掌握度。
/// 流程：generate(普通) → 阅读点击标不会（剩余默认会）→ 太难可 regenerateSimpler →
/// submit 走 World.run(UserKnownSystem .batch)（只写状态，不建卡）。
/// @ai: 生成任务托管到全局活动中心，切 Tab/销毁 View 不中断。
@MainActor
@Observable
final class VocabularyInitViewModel {

    enum Stage: Equatable {
        case idle
        case generating
        case ready
        case submitting
        case done
    }

    // MARK: - 状态

    var stage: Stage = .idle
    var paragraph: String = ""
    var words: [InitWord] = []
    /// 会话内用户点击过的词覆盖状态（lemma → 会不会）；未出现的词跟随全局记录。
    /// @ai: 三态切换依赖它区分"手动标红"与"记录来的红"。
    var sessionStates: [String: Bool] = [:]
    var errorMessage: String?
    var ease: InitEase = .medium
    var isInitialized = false

    /// 本次提交写入的词数（结果展示）。
    var submittedCount = 0
    /// 本次新增记录中"不会"的数量（done 页展示：会 = submittedCount - newUnknownCount）。
    var newUnknownCount = 0
    /// 全局掌握度概览（会/不会/出现过/未标记）。
    var overview = GraphQueries.MasteryOverview(known: 0, unknown: 0, seen: 0, unmarked: 0)
    /// 全局掌握度（lemma → mastery，0=无记录 / 1=不会 / 2=会）：已有记录的词直接标绿/标红，无记录才需用户标记。
    private(set) var masteryByLemma: [String: Double] = [:]
    /// 出现过次数（lemma → seen_count）：RSS 等文章自动记录，未判定会/不会 → 蓝色。
    private(set) var seenByLemma: [String: Int] = [:]

    // MARK: - 依赖

    let world: World
    let settings: AppSettings
    private var activityID: UUID?

    init(world: World, settings: AppSettings = .shared) {
        self.world = world
        self.settings = settings
        refreshOverview()
        loadMastery()
        isInitialized = !masteryByLemma.isEmpty
    }

    // MARK: - 派生值

    var unknownCount: Int { words.filter { markState(for: $0) == .unknown }.count }
    var knownCount: Int { max(0, words.count - unknownCount) }

    /// 当前生成模型展示（简略版：引擎 + 模型名；修改去「设置」页）。
    var generationModelLabel: String {
        switch settings.generatorTier {
        case .processLocal:
            let file = (settings.localModelPath as NSString?)?.lastPathComponent ?? "未选择模型"
            return "进程内 · \(file)"
        case .remote:
            return settings.activeAPIConfig.model
        }
    }

    /// 是否已生成可标记段落（false 时显示引导按钮）。
    var hasParagraph: Bool { stage == .ready || stage == .submitting || stage == .done }

    /// 判断某词块的显示状态（会话覆盖 > 全局掌握度 > 出现过 > 无记录）。
    /// @ai: 掌握度按 Lemma id 存储，词形先经 findLemmaId 反查；判定统一走 WordMarkState.from。
    func markState(for word: InitWord) -> WordMarkState {
        // 会话内点过：直接采用
        if let known = sessionStates[word.lemma] {
            return known ? .known : .unknown
        }
        // 全局掌握度 / 出现过 / 无记录：统一判定口径
        guard let lemmaId = try? world.graph.findLemmaId(byTextA: word.lemma) else {
            return .pending
        }
        return WordMarkState.from(
            mastery: masteryByLemma[lemmaId],
            seenCount: seenByLemma[lemmaId] ?? 0)
    }

    // MARK: - 数据

    /// 刷新全局掌握度概览。
    func refreshOverview() {
        if let o = try? world.graph.masteryOverview() {
            overview = o
        }
    }

    /// 加载全局掌握度与出现记录映射。
    func loadMastery() {
        masteryByLemma = (try? world.graph.knownLemmaMastery()) ?? [:]
        seenByLemma = (try? world.graph.allLemmaSeenCounts()) ?? [:]
    }

    // MARK: - 生成

    /// 测试注入：非 nil 时优先使用（绕过真实网络）。
    var clientOverride: (any LLMClient)?

    /// 按当前档位构造 LLM client（复用 AppSettings 配置，与 GenerateViewModel 一致）。
    private func makeClient() throws -> any LLMClient {
        if let clientOverride { return clientOverride }
        switch settings.generatorTier {
        case .processLocal:
            guard let path = settings.localModelPath, !path.isEmpty else {
                throw GenerateError.engineUnavailable(
                    "请先在「设置」→「进程内模型」选择 GGUF 模型文件（可导入或从 Ollama 提取）。")
            }
            return LlamaCPPClient(modelPath: path)
        case .remote:
            return OpenAICompatibleClient(
                baseURL: settings.llmBaseURL,
                apiKey: settings.llmAPIKey.isEmpty ? nil : settings.llmAPIKey,
                model: settings.llmModel,
                isThinking: settings.activeAPIConfig.isThinking ?? false)
        }
    }

    /// 生成一段指定难度的初始化段落（托管执行）。
    /// @ai: 新词优先策略——生成后评估"已有实词数"，过多则换话题 + 带反馈重试一次
    /// （告知 LLM 已用过的词让其自行调整用词，不做规则硬塞）。
    func generate(ease: InitEase = .medium) {
        guard stage != .generating, stage != .submitting else { return }
        self.ease = ease
        stage = .generating
        errorMessage = nil
        paragraph = ""
        words = []
        sessionStates = [:]
        do {
            let generator = VocabularyInitGenerator(client: try makeClient())
            let id = GlobalActivityCenter.shared.begin(
                title: "生成初始化段落", icon: "person.text.rectangle",
                progress: 0.0, message: "准备中…")
            activityID = id
            GlobalActivityCenter.shared.run(id) {
                do {
                    // 小模型（qwen2.5:0.5b 等）易输出过短/全是已有词：
                    // 合格标准 = 实际词数 ≥100 且新实词 ≥5；不合格带反馈（写长/换词）重试，
                    // 最多 3 次；每次都保留最长段落，3 次都不合格取最长（不浪费模型能力，保证有结果）。
                    var best: (para: InitParagraph, total: Int)?
                    var feedback: String?
                    var attempt = 0
                    while true {
                        let topic = VocabularyInitGenerator.randomTopic()
                        let r = try await generator.generate(
                            ease: ease, topic: topic, feedback: feedback)
                        let total = VocabularyInitGenerator.wordCount(r.paragraph)
                        // 评估（主线程查全局掌握度；功能词不计）
                        let stats = await MainActor.run { [weak self] in
                            guard let self else { return (new: 0, known: [] as [String]) }
                            return self.evaluateParagraph(r)
                        }
                        if best == nil || total > best!.total {
                            best = (r, total)
                        }
                        attempt += 1
                        if (total >= 100 && stats.new >= 5) || attempt >= 3 { break }
                        feedback = VocabularyInitGenerator.feedbackMessage(
                            knownWords: stats.known, tooShort: total < 100,
                            contentCount: total)
                    }
                    guard let final = best?.para else {
                        throw InitGenerateError.emptyParagraph
                    }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.paragraph = final.paragraph
                        self.words = final.words
                        self.loadMastery()  // 刷新全局掌握度，已有记录的词直接标绿/红
                        self.stage = .ready
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.errorMessage = "生成失败：\(error)"
                        self.stage = .idle
                    }
                }
            }
        } catch {
            errorMessage = "\(error)"
            stage = .idle
        }
    }

    /// 太难了 → 用更简单难度重新生成。
    func regenerateSimpler() {
        generate(ease: .intro)
    }

    // MARK: - 标记

    /// 点击词块三态循环：
    ///  无记录灰 / 出现过蓝 → 红（手动标不会）；再次点击 → 回原态
    ///  绿（会，记录或会话）→ 红（标不会）
    ///  红（来自记录）→ 绿（改判会）
    /// @ai: sessionStates 记录会话覆盖；红来自记录时点击写入 true（变绿），手动红的点击移除覆盖（回灰/跟全局）。
    /// learning（学习中）由 View 弹确认后走 setSession，不在此切换。
    func toggle(_ word: InitWord) {
        switch markState(for: word) {
        case .pending, .known, .seen, .learning:
            sessionStates[word.lemma] = false   // 灰/绿/蓝/学习中 → 红
        case .unknown:
            if sessionStates[word.lemma] == false {
                sessionStates.removeValue(forKey: word.lemma)  // 手动红 → 回灰/跟全局
            } else {
                sessionStates[word.lemma] = true   // 记录红 → 绿
            }
        }
    }

    /// 把词直接设置为会话极端状态（会/不会），提交时落库为两端极值。
    /// @ai: 用户确认后把"学习中"词覆盖为会或不会（sessionStates 优先于全局）。
    func setSession(_ word: InitWord, known: Bool) {
        sessionStates[word.lemma] = known
    }

    // MARK: - 提交

    /// 判断某词本次提交前是否**无记录**（从无到有的新增；有记录只是状态更新不算新增）。
    /// @ai: 看全局记录（masteryByLemma），与会话点击无关；0/无行 = 无记录。
    func isNewlyRecorded(_ word: InitWord) -> Bool {
        guard let lemmaId = try? world.graph.findLemmaId(byTextA: word.lemma) else {
            return true
        }
        guard let m = masteryByLemma[lemmaId] else { return true }
        return m <= 0
    }

    /// 词是否已有记录（会/不会/出现过）——生成评估"已有词出现率"用。
    /// @ai: 与词块显示口径一致（WordMarkState.from）；seen 词也算已有（用户见过）。
    func isAlreadyRecorded(_ word: InitWord) -> Bool {
        guard let lemmaId = try? world.graph.findLemmaId(byTextA: word.lemma) else {
            return false
        }
        if let m = masteryByLemma[lemmaId], m > 0 { return true }
        return (seenByLemma[lemmaId] ?? 0) > 0
    }

    /// 评估一段生成的"新词质量"：新实词数 / 已有实词列表（功能词不计）。
    /// @ai: 生成循环的合格判定依据；主线程调用（内部查全局掌握度）。
    func evaluateParagraph(_ r: InitParagraph) -> (new: Int, known: [String]) {
        var new = 0
        var known: [String] = []
        for w in r.words where !VocabularyInitGenerator.isFunctionWord(w.lemma) {
            if isAlreadyRecorded(w) {
                known.append(w.lemma)
            } else {
                new += 1
            }
        }
        return (new, known)
    }

    /// 当前段落中的新词数（未记录的实词，功能词不计）——标记页实时显示。
    var newWordCount: Int {
        words.filter {
            !VocabularyInitGenerator.isFunctionWord($0.lemma) && !isAlreadyRecorded($0)
        }.count
    }

    /// 把段落词写入全局掌握度：
    ///  - 会话点过的词按点写极端（不会 1 / 会 2）；
    ///  - 无记录词默认会（2.0）；
    ///  - 已有记录且未点（含学习中中间值）保持原掌握度，不覆盖。
    /// @ai: 词最终状态 = 会话覆盖（点过）→ 否则无记录默认会；学习中记录不被批量提交重置。
    /// submittedCount 统计的是"无记录→有记录"的新增词数。
    func submit() {
        guard stage == .ready, !words.isEmpty else { return }
        stage = .submitting
        errorMessage = nil
        // 提交前快照：只有此前无记录的词算本次新增
        let newWords = words.filter { isNewlyRecorded($0) }
        submittedCount = newWords.count
        newUnknownCount = newWords.filter { markState(for: $0) == .unknown }.count
        let batchWords = words.compactMap { word -> (word: String, known: Bool)? in
            if let known = sessionStates[word.lemma] {
                return (word.lemma, known)          // 会话点过 → 写极端
            }
            if isNewlyRecorded(word) {
                return (word.lemma, true)           // 无记录 → 默认会
            }
            return nil                              // 已有记录未点 → 保持原掌握度
        }
        do {
            try world.run(UserKnownSystem(), context: .batch(words: batchWords, source: "init"))
            isInitialized = true
            loadMastery()
            refreshOverview()
            stage = .done
        } catch {
            errorMessage = "提交失败：\(error)"
            stage = .ready
        }
    }

    /// 重新初始化（清空本次会话，再生成一段）。
    func reset() {
        stage = .idle
        paragraph = ""
        words = []
        sessionStates = [:]
        errorMessage = nil
        ease = .medium
    }
}
