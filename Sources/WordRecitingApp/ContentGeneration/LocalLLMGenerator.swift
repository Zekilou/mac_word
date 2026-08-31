import Foundation

/// 生成阶段（进度展示用）。saving 由 ViewModel 在落库前设置。
enum GenStage: Int, CaseIterable, Sendable {
    case strategy = 0
    case planning = 1
    case generating = 2
    case embedding = 3
    case polishing = 4
    case saving = 5

    var label: String {
        switch self {
        case .strategy: return "正在制定生成策略…"
        case .planning: return "正在联想打草稿…"
        case .generating: return "正在生成正文…"
        case .embedding: return "正在逐词融入…"
        case .polishing: return "正在改写润色…"
        case .saving: return "正在保存…"
        }
    }
}

/// 生成过程进度事件：阶段切换 或 流式 token。
enum GenProgress: Sendable {
    case stage(GenStage)
    case token(String)
    /// 逐词融入进度：已处理（0 基）/总数/当前词。
    case word(done: Int, total: Int, word: String)
    /// 一条思考记录（供左侧进度区渲染思考日志）。
    case thought(GenThought)
}

/// 生成过程中的一条思考记录（VM 按 id upsert 成日志）。
struct GenThought: Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case strategy, planning, generating, embedding, polishing, saving, info
    }
    enum Status: String, Sendable { case running, done, failed }
    let id: String
    let kind: Kind
    let message: String
    let detail: String?
    let status: Status
}

/// 流式标记缓冲的引用包装：@Sendable onToken 回调内需可变捕获，值类型必须装进引用容器。
final class StreamBufferBox: @unchecked Sendable {
    var buffer = MarkedStreamBuffer()
}

/// 流结束收尾：冲洗思考行提取器尾部（跨块切碎的 THINKING 行 / 无换行结尾）。
/// 提取到的思考行转思考事件；正文内容经缓冲区 + 守卫后推送 .token（与流内同一处理）。
/// @ai: 不加这段，单行/末尾无换行的输出会被提取器滞留丢失，正文被截断。
func flushThinkingStream(
    thinkBox: ThinkingLineExtractorBox,
    buffer: StreamBufferBox,
    guardBox: LeadingLineGuardBox,
    onProgress: (@Sendable (GenProgress) -> Void)?
) {
    let (tail, tailThoughts) = thinkBox.extractor.finalize()
    for t in tailThoughts {
        thinkBox.seq += 1
        onProgress?(.thought(GenThought(
            id: "model-\(thinkBox.seq)", kind: .info,
            message: "模型：\(t)", detail: nil, status: .running)))
    }
    guard !tail.isEmpty else { return }
    let clean = buffer.buffer.append(tail)
    let visible = guardBox.guardValue.append(clean)
    if !visible.isEmpty { onProgress?(.token(AgenticPrompts.strippingMarkerLines(visible))) }
}

/// 本地 LLM 生成错误。
enum ArticleGenError: LocalizedError, Sendable, Equatable {
    /// 模型未产出有效正文（只有写作自述 / NO_ARTICLE / 空），不落库。
    case noArticle

    var errorDescription: String? {
        switch self {
        case .noArticle: return "模型未生成有效正文（只有写作说明/空），请重试。"
        }
    }
}

/// 本地 LLM 造文/改写生成器（tier = .local）。
/// 用任意 LLMClient 后端生成：主题 + 目标词 → prompt → 文章。
/// 生成后用与 RuleBasedGenerator 相同的词扫描逻辑标记目标词 spans（isTarget=true）。
/// @ai: 只读 graph，不写库；落库由 ContentGenSystem 负责。
struct LocalLLMGenerator: ContentGenerator {
    static let identifier = "local-llm"
    static let tier: QualityTier = .local

    let client: any LLMClient
    let temperature: Double
    /// 模型上下文窗口（tokens）：长 prompt 压缩判断依据（本地 llama.cpp 默认 2048，远端按模型调大）。
    let contextWindow: Int
    /// 正文输出 token 上限（nil = 自动按目标字数动态算；>0 = 用户固定覆盖）。
    let outputTokenLimit: Int?
    /// 生成过程进度回调（阶段切换 + 流式 token），nil = 不展示进度。
    var onProgress: (@Sendable (GenProgress) -> Void)?
    /// 客户端是否为思考型模型（探测后传入）。思考型走浅管线：计划一次性并入初始 prompt，
    /// 模型自行思考+写作+自查，不再被强制走 strategy/planning/polish 多轮独立调用。
    var isThinking: Bool = false
    /// 语义锚点选句用的词向量（可选；nil = 回退 LLM 联想/词面匹配）。
    /// @ai: 全模型统一走"草稿不喂词 → embedding 余弦选锚 → 逐词改写"，这是 RAG 式按需查询。
    var embeddingProvider: EmbeddingProvider?

    init(
        client: any LLMClient, maxTokens: Int = 600, temperature: Double = 0.7,
        contextWindow: Int = 2048, outputTokenLimit: Int? = nil,
        onProgress: (@Sendable (GenProgress) -> Void)? = nil,
        isThinking: Bool = false,
        embeddingProvider: EmbeddingProvider? = nil
    ) {
        self.client = client
        self.temperature = temperature
        self.contextWindow = contextWindow
        // 兼容旧 maxTokens 参数（显式传值时作为固定输出上限）
        self.outputTokenLimit = outputTokenLimit ?? (maxTokens != 600 ? maxTokens : nil)
        self.onProgress = onProgress
        self.isThinking = isThinking
        self.embeddingProvider = embeddingProvider
    }

    /// 正文生成的输出 token 预算：
    /// 默认**按目标字数动态计算**（字数×1.5+200，至少 256）——100 词→350、300 词→650、2000 词→3200，
    /// 并 clamp 到上下文窗口的 3/4（给输入 prompt 留空间）；用户设置固定上限时用该值。
    /// @ai: 旧版硬编码 600，字数大时输出被截断 → noArticle/坏记录；现与字数联动。
    func bodyMaxTokens(maxWords: Int) -> Int {
        let auto = max(256, maxWords * 3 / 2 + 200)
        let cap = max(256, contextWindow * 3 / 4)
        let v = outputTokenLimit ?? auto
        return min(v, cap)
    }

    /// 上下文压缩：估算 prompt token，超窗预算（窗口 − 输出预算 − 安全边距 256）时截断。
    /// @ai: 长文章自查/大计划场景防止 prompt 超 n_ctx 导致解码失败或输出被挤没；
    ///      **protectedPrefix（强制规则区）常驻不可压缩**——prompt 以规则块开头，压缩只作用于其后的
    ///      可变内容（词列表/计划/文章），规则永不丢失（用户要求：规则不能压缩，词列表可截断）。
    func compressContext(_ prompt: String, reservedForOutput: Int, protectedPrefix: String = "") -> String {
        let budget = contextWindow - reservedForOutput - 256
        guard budget > 0, ContextCompressor.estimateTokens(prompt) > budget else { return prompt }
        guard !protectedPrefix.isEmpty else {
            return ContextCompressor.truncate(prompt, toBudget: budget)
        }
        let prefixTokens = ContextCompressor.estimateTokens(protectedPrefix)
        let contentBudget = max(64, budget - prefixTokens)
        return protectedPrefix + ContextCompressor.truncate(
            String(prompt.dropFirst(protectedPrefix.count)), toBudget: contentBudget)
    }

    func generate(
        mode: GenerationMode,
        sourceText: String?,
        targetLemmas: [EntityID],
        constraints: GenerationConstraints,
        graph: GraphQueries
    ) async throws -> GeneratedArticle {
        // 目标词的干净表面形式（用于 prompt 与 span 扫描）
        let surfaces = try graph.lemmaSurfaces(for: targetLemmas)
        let words = surfaces.values.sorted()
        // 主题可留空：空主题时由目标词驱动成文（词驱动），避免生僻词被硬塞进无关主题。
        let theme = (sourceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? sourceText!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (constraints.topic ?? "")

        // 思考型模型：也走 RAG 逐词管线（草稿不喂词 → embedding 选锚 → 逐词改写嵌入）。
        // @ai: 用户确认——不管大小模型统一按需查询，不把所有词一次性塞进 prompt；
        //      思考型不再走 thinkingPrompt 全词单次（浪费上下文、嵌入率低）。
        if isThinking, mode == .generate, !words.isEmpty {
            return try await generateViaRewrite(
                theme: theme, words: words, maxWords: constraints.maxWords,
                strategy: GenStrategy(mode: .generateRewrite),
                surfaces: surfaces, targetLemmas: targetLemmas,
                constraints: constraints, graph: graph)
        }

        /// 规划 pass 产出（generate 模式；rewrite 模式为 nil）。
        var plan: String?
        /// 策略 pass 决策（仅 generate 模式有值；rewrite 模式为 nil，展示思考链用）。
        var strategy: GenStrategy?
        let prompt: String
        if mode == .generate {
            onProgress?(.stage(.strategy))
            onProgress?(.thought(GenThought(
                id: "strategy", kind: .strategy,
                message: "正在制定生成策略…", detail: nil, status: .running)))
            try Task.checkCancellation()
            var decided = GenStrategy()
            if !words.isEmpty {
                if let raw = try? await client.complete(
                    prompt: GenStrategyPrompt.strategyPrompt(theme: theme, words: words),
                    maxTokens: 120, temperature: 0.2) {
                    decided = GenStrategyPrompt.parse(raw)
                }
            }
            strategy = decided
            let modeLabel = decided.mode == .generateRewrite ? "先写后改写（generate-rewrite）" : "按计划嵌入（plan-embed）"
            onProgress?(.thought(GenThought(
                id: "strategy", kind: .strategy,
                message: "策略：\(modeLabel)", detail: nil, status: .done)))
            if decided.mode == .generateRewrite {
                return try await generateViaRewrite(
                    theme: theme, words: words, maxWords: constraints.maxWords,
                    strategy: decided, surfaces: surfaces, targetLemmas: targetLemmas,
                    constraints: constraints, graph: graph)
            }
            onProgress?(.stage(.planning))
            onProgress?(.thought(GenThought(
                id: "planning", kind: .planning,
                message: "正在联想词义并打草稿…", detail: nil, status: .running)))
            try Task.checkCancellation()
            if !words.isEmpty {
                if let planned = try? await client.complete(
                    prompt: Self.planPrompt(theme: theme, words: words, maxWords: constraints.maxWords),
                    maxTokens: 240, temperature: 0.3) {
                    let cleaned = Self.cleanArticle(planned)
                    plan = cleaned.isEmpty ? nil : cleaned
                }
            }
            let wordCount = words.count
            onProgress?(.thought(GenThought(
                id: "planning", kind: .planning,
                message: "规划完成（\(wordCount) 词）", detail: plan, status: .done)))
            prompt = Self.generatePrompt(
                theme: theme, words: words, maxWords: constraints.maxWords, plan: plan)
        } else {
            prompt = Self.rewritePrompt(
                source: sourceText ?? "", words: words, maxWords: constraints.maxWords)
        }

        onProgress?(.stage(.generating))
        onProgress?(.thought(GenThought(
            id: "draft", kind: .generating,
            message: "正在生成正文…", detail: nil, status: .running)))
        try Task.checkCancellation()
        let outputBudget = bodyMaxTokens(maxWords: constraints.maxWords)
        let finalPrompt = compressContext(
            prompt, reservedForOutput: outputBudget, protectedPrefix: Self.hardRules)
        let streamBox = StreamBufferBox()
        let streamGuard = LeadingLineGuardBox()
        let thinkBox = ThinkingLineExtractorBox()
        _ = try await client.stream(
            prompt: finalPrompt, maxTokens: outputBudget, temperature: temperature
        ) { [onProgress] token in
            let (vis, thoughts) = thinkBox.extractor.append(token)
            for t in thoughts {
                thinkBox.seq += 1
                onProgress?(.thought(GenThought(
                    id: "model-\(thinkBox.seq)", kind: .info,
                    message: "模型：\(t)", detail: nil, status: .running)))
            }
            guard !vis.isEmpty else { return }
            let clean = streamBox.buffer.append(vis)
            let visible = streamGuard.guardValue.append(clean)
            if !visible.isEmpty { onProgress?(.token(AgenticPrompts.strippingMarkerLines(visible))) }
        }
        // 流结束：冲洗思考行提取器尾部（单行/无换行结尾不会被滞留丢失）
        flushThinkingStream(thinkBox: thinkBox, buffer: streamBox, guardBox: streamGuard, onProgress: onProgress)
        var body = AgenticPrompts.extractMarkedBody(streamBox.buffer.rawAll)
        onProgress?(.thought(GenThought(
            id: "draft", kind: .generating,
            message: "生成正文完成（\(streamBox.buffer.rawAll.count) 字符）", detail: nil, status: .done)))
        if !body.isEmpty {
            onProgress?(.stage(.polishing))
            onProgress?(.thought(GenThought(
                id: "polish", kind: .polishing,
                message: "正在改写润色…", detail: nil, status: .running)))
            try Task.checkCancellation()
            let polishBox = StreamBufferBox()
            let polishGuard = LeadingLineGuardBox()
            let polishThinkBox = ThinkingLineExtractorBox()
            let polishPrompt = compressContext(
                Self.polishPrompt(article: body),
                reservedForOutput: bodyMaxTokens(maxWords: constraints.maxWords),
                protectedPrefix: Self.reviewInstructions)
            let polished = try? await client.stream(
                prompt: polishPrompt,
                maxTokens: bodyMaxTokens(maxWords: constraints.maxWords), temperature: 0.3,
                onToken: { [onProgress] token in
                    let (vis, thoughts) = polishThinkBox.extractor.append(token)
                    for t in thoughts {
                        polishThinkBox.seq += 1
                        onProgress?(.thought(GenThought(
                            id: "model-\(polishThinkBox.seq)", kind: .info,
                            message: "模型：\(t)", detail: nil, status: .running)))
                    }
                    guard !vis.isEmpty else { return }
                    let clean = polishBox.buffer.append(vis)
                    let visible = polishGuard.guardValue.append(clean)
                    if !visible.isEmpty { onProgress?(.token(AgenticPrompts.strippingMarkerLines(visible))) }
                })
            // 流结束：冲洗自查流尾部（防末尾无换行行被截断）
            flushThinkingStream(thinkBox: polishThinkBox, buffer: polishBox, guardBox: polishGuard, onProgress: onProgress)
            if let polished, !polished.isEmpty {
                let cleaned = AgenticPrompts.extractMarkedBody(polishBox.buffer.rawAll)
                if !cleaned.isEmpty { body = cleaned }
            }
            // 校验自查结果：模型确认整篇无正文（只输出 NO_ARTICLE / 空）→ 视为生成失败，不落库
            if Self.isNoArticle(body) {
                throw ArticleGenError.noArticle
            }
            onProgress?(.thought(GenThought(
                id: "polish", kind: .polishing,
                message: "润色完成", detail: nil, status: .done)))
        }
        // 最终正文兜底：容错剥离标记（防变体标记漏进展示）
        body = AgenticPrompts.extractMarkedBody(body)
        // 最终校验：正文为空 → 生成失败
        guard !Self.isNoArticle(body) else {
            throw ArticleGenError.noArticle
        }
        var spans = Self.findTargetSpans(body: body, surfaces: surfaces)

        // fallback：LLM 未嵌目标词 → 用规则替换把文中同义词替换为缺失词。
        // 融不进去的词（文中无可用同义词）直接跳过，不硬塞。
        let foundIds = Set(spans.compactMap { $0.lemmaId })
        let missingIds = targetLemmas.filter { !foundIds.contains($0) }
        if !missingIds.isEmpty {
            let rule = RuleBasedGenerator()
            let rewritten = try await rule.generate(
                mode: .rewrite,
                sourceText: body,
                targetLemmas: missingIds,
                constraints: constraints,
                graph: graph)
            if !rewritten.spans.isEmpty {
                body = rewritten.body
                spans = Self.findTargetSpans(body: body, surfaces: surfaces)
            }
        }

        return GeneratedArticle(
            body: body, spans: spans,
            generatorId: Self.identifier, tier: Self.tier,
            plan: plan, strategy: strategy)
    }

    // MARK: - 思考型模型浅管线（已并入 RAG 逐词管线：generate() 中 isThinking 分支直接走 generateViaRewrite）

    // MARK: - Prompt 构造

    /// 规划 pass prompt：目标词语义聚类成子主题段落 + 逻辑连接词单独处理 + 出大纲。
    /// @ai: 依据 Topic Drift 研究（Idea-Gated, arXiv 2512.03343）：先生成全局语义计划再写作，
    /// 内容词归入最贴切的簇，逻辑词（however/therefore）作段落衔接；决策权全在 LLM。
    static func planPrompt(theme: String, words: [String], maxWords: Int) -> String {
        let wordList = words.isEmpty ? "(no specific words)" : words.joined(separator: ", ")
        let topicLine = theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "You are planning an English article built around these target words — the words themselves shape the topic."
            : "You are planning an English article about: \(theme)."
        return """
        \(topicLine)

        Target vocabulary (may be randomly sampled from many topics): \(wordList)

        Organize the article so every word feels at home, even when the words come from
        very different topics.

        Step 1 - Cluster the words by meaning:
        - Group the target words into 2-4 clusters. Each cluster shares a theme and will
          become one paragraph of the article.
        - A word with a narrow meaning goes into the cluster it fits best.
        - Words that express logic (e.g. however, therefore, although, instead, still)
          are CONNECTORS: do not put them in a cluster, list them separately for linking
          paragraphs.

        Step 2 - Plan the paragraphs:
        - For each cluster write one line: the paragraph's theme + which words it will
          use, and how each word fits the theme.
        - Give 3-5 outline bullet points for the paragraph order.

        Use every word as an ordinary part of a sentence — NEVER as a dictionary entry.
        Do NOT write the article yet. Output ONLY the plan as short bullet points:
        "Clusters:" (one bullet per cluster), "Connectors:" (logic words, if any),
        "Outline:" (paragraph order).
        """
    }

    /// 强制规则块：置于所有正文/自查 prompt 最前，**压缩时受保护常驻**（不可被上下文压缩截断）。
    /// @ai: 用户要求——规则性质的放前面，词列表/计划被截断没关系，但强制规则不能被压缩。
    ///      与 compressContext(protectedPrefix:) 配合：prompt 必须以本块开头，压缩只截其后内容。
    static let hardRules: String = """
    STRICTLY FORBIDDEN (these rules are ALWAYS in effect, no exceptions):
    - any sentence that defines, translates, or explains a target word like a dictionary
      entry (for example "X means Y", "X is a form of Y", "The term X refers to ...",
      "X, which is ..."),
    - a word list or glossary at the end,
    - Do NOT repeat, restate, or quote the writing plan,
    - any sentence about the text itself, the draft, editing, the writer, or this task
      (for example "I am not sure whether my draft is ready"),
    - NEVER narrate your own writing process: no "Let me ..." lines, no notes about
      planning, re-reading, restructuring, or checking the text.

    Write the article directly as a normal text about the topic only. Output ONLY the
    article body wrapped in the ARTICLE markers, nothing outside them.
    """

    static func generatePrompt(theme: String, words: [String], maxWords: Int, plan: String? = nil) -> String {
        let wordList = words.isEmpty ? "(no specific words)" : words.joined(separator: ", ")
        let topicLine = theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Write a natural, engaging English article woven around these target words — the words themselves shape the topic."
            : "Write a natural, engaging English article about: \(theme)."
        let planSection = plan.map { "\n\nWriting plan to follow (use the target words exactly where planned):\n\($0)" } ?? ""
        return """
        \(Self.hardRules)

        \(topicLine)

        Target vocabulary: \(wordList)

        Requirements:
        - Follow your plan: write the article as paragraphs, one theme per paragraph,
          and place each target word in its planned paragraph as an ordinary word.
        - Use connector words between paragraphs where they help the flow.
        - Include as many target words as you can; if a word truly does not fit the
          topic or would read forced, it is better to omit it than to force it in.
        - You may use inflected forms (e.g. "abandoned", "battles") when it reads naturally.
        - Paragraph layout: separate paragraphs with one blank line; write full paragraphs
          (3-5 sentences each). Do NOT leave a single sentence as its own paragraph.
        - Length: about \(maxWords) words.
        - Style: plain, fluent English suitable for an intermediate learner.
        - Wrap the output exactly with:
          ===ARTICLE_START===
          (content)
          ===ARTICLE_END===
        - Output nothing outside these markers.
        \(planSection)
        """
    }

    static func rewritePrompt(source: String, words: [String], maxWords: Int) -> String {
        """
        Rewrite the following English text so that it naturally includes as many of these
        words as fit (use inflected forms if needed): \(words.isEmpty ? "(none)" : words.joined(separator: ", ")).

        Requirements:
        - Keep the original meaning and tone; the result should read like natural English.
        - If a word would read forced, omit it rather than force it in.
        - Do NOT define or explain the words, and do NOT add a word list or glossary.
        - Output ONLY the rewritten article body.
        - Wrap the output exactly with:
          ===ARTICLE_START===
          (content)
          ===ARTICLE_END===
        - Output nothing outside these markers.
        - Approximate length: \(maxWords) words.

        Original text:
        \(source)
        """
    }

    // MARK: - 输出清洗

    /// 去掉模型可能输出的 markdown 围栏 / 前导说明 / 行内多余空白。
    static func cleanArticle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // 去掉 ``` 围栏（可能带语言标记）
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            let withoutFence = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            s = withoutFence.joined(separator: "\n")
        }
        // 统一换行符，折叠连续 3+ 空行为段落空行（避免模型输出大量空行造成大片空白）
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        // 每行去掉行首行尾多余空白（模型可能输出缩进/补空格造成排版错乱）
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 自查指令（**独立干净上下文**）：不携带生成侧 hardRules。
    /// @ai: 用户要求"新会话隔离上下文"——自查若重复大段规则文本，小模型容易回显规则/被上下文带偏
    ///      （曾出现正文抄 "The rules of the game are always in effect"）；自查只聚焦"明显异常"，指令精简。
    static let reviewInstructions: String = """
    You are a careful editor. Review the English article below and fix ONLY obvious problems:
    - remove any sentence that defines, translates, or explains a word like a dictionary
      entry (for example "X means Y", "The term X refers to ...", "X is a form of Y",
      "X, which is ..."),
    - remove sentences that read forced or unnatural because a specific word was squeezed in,
    - remove a word list / glossary at the end,
    - remove sentences that talk about the text itself, the draft, editing, the writer,
      or this task, or that narrates the writer's own thinking or writing process
      (for example "Let me re-read the thought process", "I'm getting ahead of myself"),
    - remove sentences that repeat the task's own instructions or rules (for example
      text starting with "STRICTLY FORBIDDEN" or "The rules of the game"),
    - remove sentences containing phonetic symbols or audio file names (like "[hɔ:nt]"
      or "file.mp3"),
    - remove a plan, outline, or numbered list of paragraphs (for example "Paragraph 1: ...").

    If the text begins with a plan/outline block, remove that block entirely.
    If the text contains NO actual article content at all — only notes about the writing
    process, word choice, spelling, or this task — remove everything and output exactly:
    NO_ARTICLE

    The final text must read like a normal article; no sentence may explain a word.
    Keep everything else EXACTLY as it is. Do not add new content.
    Output ONLY the cleaned article text, wrapped exactly with:
    ===ARTICLE_START===
    (content)
    ===ARTICLE_END===
    Output nothing outside these markers.

    Article:
    """

    /// 自查 prompt：让模型自己检查正文，删掉释义式/生硬/规则回显/音标等明显异常。
    /// @ai: 独立干净上下文（仅指令 + 文章，不重复生成侧 hardRules），压缩时保护指令区。
    static func polishPrompt(article: String) -> String {
        Self.reviewInstructions + article + "\n"
    }

    /// 判定正文是否"无有效内容"：空、只有 NO_ARTICLE 哨兵，或全为写作自述/元注释短句，
    /// 或含明显异常（释义开头/规则文本回显/音标音频混入）。
    /// @ai: 自查或最终校验用；模型确认无正文时不允许落库。
    /// 启发式只匹配明确的异常模式（防误伤正常文章）；明显异常即使 ≥100 字符也拦（程序兜底）。
    static func isNoArticle(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // 哨兵变体：(No_article) / NO_ARTICLE / <NO_ARTICLE> / No Article 等——
        // 模型常给哨兵加括号/尖括号/下划线/混合大小写，剥掉所有非字母后统一判定，防漏网落库
        let allLetters = trimmed.uppercased().filter { $0.isLetter }
        if allLetters == "NOARTICLE" || allLetters == "NOARTRICLE" { return true }
        let lower = trimmed.lowercased()
        // 明显异常（模型自查失败时程序兜底，防坏记录落库；正常文章几乎不会出现这些特征）：
        // 1) 音标 / 音频文件名混入（词库脏数据）
        if lower.contains(".mp3") || lower.contains(".wav") { return true }
        // 2) 规则文本回显（hardRules 措辞）
        if lower.contains("strictly forbidden") || lower.contains("always in effect")
            || lower.hasPrefix("the rules of the game") { return true }
        // 2b) 思考通道标记泄漏（DeepSeek 思考通道把 <|channel|> / <channel|> 写进正文）
        if lower.contains("|channel") { return true }
        // 2c) 上下文压缩占位符被复述（模型把省略标记当正文写进文章：
        //     "[...上下文过长，中间已省略...]" / "[...]" / 中文省略说明）
        if lower.contains("[...") || lower.contains("上下文过长") || lower.contains("中间已省略") {
            return true
        }
        // 3) 释义开头（"The word X is used to describe..." / "The term X is a word that..."）
        if (lower.hasPrefix("the word ") || lower.hasPrefix("the term "))
            && (lower.contains("is a word that") || lower.contains("is used to describe")
                || lower.contains("refers to a") || lower.contains("means to")) {
            return true
        }
        // 4) 单词表/释义条目形态：正文混入 NO_ARTICLE 哨兵行（模型自查已判无正文但没删干净）；
        //    或全文只有 "- " 列表条目、没有任何独立正常句子（词表/glossary 形态，如 "词\n- 释义"）
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // 行级哨兵子串：含正常哨兵或拼写变体（NO_ARTRICLE / <channel|>NO_ARTRICLE 等真实落库形态）
        if lines.contains(where: {
            let letters = $0.uppercased().filter { $0.isLetter }
            return letters.contains("NOARTICLE") || letters.contains("NOARTRICLE")
        }) {
            return true
        }
        let nonEmpty = lines.filter { !$0.isEmpty }
        let listLines = nonEmpty.filter { $0.hasPrefix("- ") || $0.hasPrefix("• ") }.count
        let normalSentenceLines = nonEmpty.filter {
            !($0.hasPrefix("- ") || $0.hasPrefix("• "))
                && ($0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?"))
        }.count
        if listLines >= 2, normalSentenceLines == 0 {
            return true
        }
        // 5) 释义式开头（词典条目句式）：第一句以「普通大写名词 + is a/an/the · means · refers to」开头，
        //    如 "Affection is a deep and lasting emotional connection that..." / "Haunting is a phenomenon that..."
        //    对齐 Python 段首释义判定（_is_definition_para），仅查首段降低误伤
        let stopHeads: Set<String> = ["The", "This", "That", "These", "Those", "It", "In", "On",
            "At", "A", "An", "And", "But", "For", "With", "From", "Each", "Every", "What", "How",
            "Why", "When", "Where", "There", "Our", "We", "You", "One", "As", "If", "No", "So",
            "Some", "Such", "Their"]
        let firstPara = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? trimmed
        let firstSentence = firstPara.split(
            whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" }).first.map(String.init) ?? firstPara
        if let head = firstSentence.split(whereSeparator: { !$0.isLetter }).first,
           head.count >= 4, !stopHeads.contains(String(head)),
           firstSentence.lowercased().hasPrefix(head.lowercased()) {
            let rest = String(firstSentence.dropFirst(head.count)).lowercased()
            let defMarkers = [" is a ", " is an ", " is the ", " means ", " refers to ", " are "]
            if defMarkers.contains(where: { rest.contains($0) }) { return true }
        }
        // 过短且是写作自述/元注释（如 "The word 'esthetically' is the US spelling, I will use it."）
        let words = trimmed.split(whereSeparator: { !$0.isLetter }).count
        if trimmed.count < 100, words <= 16 {
            let selfTalk = ["is the us spelling", "i will use it", "let me re-read",
                            "i'm getting ahead", "not sure whether", "this is a note",
                            "i should rewrite", "i chose to"]
            return selfTalk.contains { lower.contains($0) }
        }
        return false
    }

    // MARK: - Span 扫描

    /// 扫描 body 中出现的所有目标词表面形式，生成 spans（大小写不敏感）。
    /// 与 RuleBasedGenerator 造文的扫描策略一致。
    static func findTargetSpans(body: String, surfaces: [EntityID: String]) -> [SpanInfo] {
        let chars = Array(body)
        let surfaceLookup: [String: EntityID] = surfaces.reduce(into: [:]) { acc, kv in
            acc[kv.value.lowercased()] = kv.key
        }
        guard !surfaceLookup.isEmpty else { return [] }

        var spans: [SpanInfo] = []
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                var j = i
                while j < chars.count && chars[j].isLetter { j += 1 }
                let word = String(chars[i..<j]).lowercased()
                if let lid = surfaceLookup[word] {
                    spans.append(SpanInfo(
                        start: i, end: j, isTarget: true, lemmaId: lid,
                        surfaceForm: String(chars[i..<j]),
                        replacedFrom: nil, weight: nil, sourceType: nil))
                }
                i = j
            } else {
                i += 1
            }
        }
        return spans
    }
}
