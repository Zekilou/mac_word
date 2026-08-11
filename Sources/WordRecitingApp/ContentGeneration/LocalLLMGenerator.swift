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
struct GenThought: Sendable {
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

/// 本地 LLM 造文/改写生成器（tier = .local）。
/// 用任意 LLMClient 后端生成：主题 + 目标词 → prompt → 文章。
/// 生成后用与 RuleBasedGenerator 相同的词扫描逻辑标记目标词 spans（isTarget=true）。
/// @ai: 只读 graph，不写库；落库由 ContentGenSystem 负责。
struct LocalLLMGenerator: ContentGenerator {
    static let identifier = "local-llm"
    static let tier: QualityTier = .local

    let client: any LLMClient
    let maxTokens: Int
    let temperature: Double
    /// 生成过程进度回调（阶段切换 + 流式 token），nil = 不展示进度。
    var onProgress: (@Sendable (GenProgress) -> Void)?

    init(
        client: any LLMClient, maxTokens: Int = 600, temperature: Double = 0.7,
        onProgress: (@Sendable (GenProgress) -> Void)? = nil
    ) {
        self.client = client
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.onProgress = onProgress
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
        let theme = (sourceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? sourceText!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (constraints.topic ?? "general")

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
        let streamBox = StreamBufferBox()
        _ = try await client.stream(
            prompt: prompt, maxTokens: maxTokens, temperature: temperature
        ) { [onProgress] token in
            let clean = streamBox.buffer.append(token)
            if !clean.isEmpty { onProgress?(.token(clean)) }
        }
        var body = Self.cleanArticle(streamBox.buffer.finalize())
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
            let polished = try? await client.stream(
                prompt: Self.polishPrompt(article: body),
                maxTokens: maxTokens, temperature: 0.3,
                onToken: { [onProgress] token in
                    let clean = polishBox.buffer.append(token)
                    if !clean.isEmpty { onProgress?(.token(clean)) }
                })
            if let polished, !polished.isEmpty {
                let cleaned = Self.cleanArticle(polishBox.buffer.finalize())
                if !cleaned.isEmpty { body = cleaned }
            }
            onProgress?(.thought(GenThought(
                id: "polish", kind: .polishing,
                message: "润色完成", detail: nil, status: .done)))
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

    // MARK: - Prompt 构造

    /// 规划 pass prompt：目标词语义聚类成子主题段落 + 逻辑连接词单独处理 + 出大纲。
    /// @ai: 依据 Topic Drift 研究（Idea-Gated, arXiv 2512.03343）：先生成全局语义计划再写作，
    /// 内容词归入最贴切的簇，逻辑词（however/therefore）作段落衔接；决策权全在 LLM。
    static func planPrompt(theme: String, words: [String], maxWords: Int) -> String {
        let wordList = words.isEmpty ? "(no specific words)" : words.joined(separator: ", ")
        return """
        You are planning an English article about: \(theme).

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

    static func generatePrompt(theme: String, words: [String], maxWords: Int, plan: String? = nil) -> String {
        let wordList = words.isEmpty ? "(no specific words)" : words.joined(separator: ", ")
        let planSection = plan.map { "\n\nWriting plan to follow (use the target words exactly where planned):\n\($0)" } ?? ""
        return """
        Write a natural, engaging English article about: \(theme).

        Target vocabulary: \(wordList)

        Requirements:
        - Follow your plan: write the article as paragraphs, one theme per paragraph,
          and place each target word in its planned paragraph as an ordinary word.
        - Use connector words between paragraphs where they help the flow.
        - Include as many target words as you can; if a word truly does not fit the
          topic or would read forced, it is better to omit it than to force it in.
        - You may use inflected forms (e.g. "abandoned", "battles") when it reads naturally.
        - STRICTLY FORBIDDEN: any sentence that defines, translates, or explains a target
          word (for example "X means Y", "X is a form of Y", "The term X refers to ...",
          "X, which is ..."). The article must be a normal text about the topic only.
        - Do NOT add a word list or glossary at the end.
        - Paragraph layout: separate paragraphs with one blank line; write full paragraphs
          (3-5 sentences each). Do NOT leave a single sentence as its own paragraph.
        \(planSection)
        Additional requirements:
        - Length: about \(maxWords) words.
        - Style: plain, fluent English suitable for an intermediate learner.
        - Output ONLY the article body.
        - Wrap the output exactly with:
          ===ARTICLE_START===
          (content)
          ===ARTICLE_END===
        - Output nothing outside these markers.
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

    /// 自查 prompt：让模型自己检查正文，删掉释义式/生硬的句子。
    /// @ai: 不用规则枚举"释义的多种表述"，交给模型自行判断。
    static func polishPrompt(article: String) -> String {
        """
        Review the following English article.

        Remove or naturally rewrite ANY sentence that:
        - defines, translates, or explains a word like a dictionary entry (for example
          "X means Y", "The term X refers to ...", "X is a form of Y", "X, which is ..."),
        - reads forced or unnatural because a specific word was squeezed in,
        - or is part of a word list / glossary.

        The final text must read like a normal article; no sentence may explain a word.
        Keep everything else EXACTLY as it is. Do not add new content.
        Output ONLY the cleaned article text.
        - Wrap the output exactly with:
          ===ARTICLE_START===
          (content)
          ===ARTICLE_END===
        - Output nothing outside these markers.

        Article:
        \(article)
        """
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
