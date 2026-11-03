import Foundation

/// Agentic 逐词融入的管线（extension）：纯净草稿 → 切句 → 联想锚点 → 逐词循环 → 回填润色 → 规则兜底。
/// @ai: 取代旧的整篇一次改写；逐词闭环在 embedWord（AgenticLoop）。
extension LocalLLMGenerator {

    /// generate-rewrite 的新实现（由 generate() 在 strategy.mode == .generateRewrite 时调用）。
    func generateViaRewrite(
        theme: String, words: [String], maxWords: Int, strategy: GenStrategy,
        surfaces: [EntityID: String], targetLemmas: [EntityID],
        constraints: GenerationConstraints, graph: GraphQueries
    ) async throws -> GeneratedArticle {
        let config = EmbedConfig(verification: constraints.embeddingVerification)

        // 1. 纯净草稿（不约束目标词）
        onProgress?(.stage(.generating))
        onProgress?(.thought(GenThought(
            id: "draft", kind: .generating,
            message: "正在生成正文…", detail: nil, status: .running)))
        try Task.checkCancellation()
        let draftBox = StreamBufferBox()
        let draftGuard = LeadingLineGuardBox()
        let draftThinkBox = ThinkingLineExtractorBox()
        let draftBudget = bodyMaxTokens(maxWords: maxWords)
        let draftPrompt = compressContext(
            GenStrategyPrompt.plainPrompt(theme: theme, maxWords: maxWords),
            reservedForOutput: draftBudget, protectedPrefix: Self.hardRules)
        _ = try await client.stream(
            prompt: draftPrompt, maxTokens: draftBudget, temperature: temperature
        ) { [onProgress] token in
            let (vis, thoughts) = draftThinkBox.extractor.append(token)
            for t in thoughts {
                draftThinkBox.seq += 1
                onProgress?(.thought(GenThought(
                    id: "model-\(draftThinkBox.seq)", kind: .info,
                    message: "模型：\(t)", detail: nil, status: .running)))
            }
            guard !vis.isEmpty else { return }
            let clean = draftBox.buffer.append(vis)
            let visible = draftGuard.guardValue.append(clean)
            if !visible.isEmpty { onProgress?(.token(AgenticPrompts.strippingMarkerLines(visible))) }
        }
        // 流结束：冲洗思考行提取器尾部（单行/无换行结尾不会被滞留丢失）
        flushThinkingStream(thinkBox: draftThinkBox, buffer: draftBox, guardBox: draftGuard, onProgress: onProgress)
        var body = AgenticPrompts.extractMarkedBody(draftBox.buffer.rawAll)
        onProgress?(.thought(GenThought(
            id: "draft", kind: .generating,
            message: "草稿完成（\(draftBox.buffer.rawAll.count) 字符）", detail: nil, status: .done)))

        var skipped: [SkippedWord] = []
        if !words.isEmpty, !body.isEmpty {
            // 2. 切句
            let sentences = SentenceSplitter.split(body)
            if sentences.isEmpty {
                skipped = words.map { SkippedWord(word: $0, reason: "草稿为空或无法断句") }
            } else {
                // 3. 联想 + 锚点（一次调用；embedding 可用时优先语义选锚）
                onProgress?(.stage(.embedding))
                onProgress?(.thought(GenThought(
                    id: "anchor", kind: .planning,
                    message: "正在联想并匹配锚点句…", detail: nil, status: .running)))
                let wordLemmaMap = surfaces.reduce(into: [String: EntityID]()) { acc, kv in
                    acc[kv.value] = kv.key
                }
                let anchors = await resolveAnchors(
                    words: words, sentences: sentences,
                    wordLemmaMap: wordLemmaMap, graph: graph)
                onProgress?(.thought(GenThought(
                    id: "anchor", kind: .planning,
                    message: "锚点匹配完成（\(anchors.count) 词）", detail: nil, status: .done)))

                // 4. 逐词循环
                var replacements: [Int: String] = [:]
                var used = Set(anchors.map(\.sentenceIndex))
                for (i, a) in anchors.enumerated() {
                    onProgress?(.word(done: i, total: anchors.count, word: a.word))
                    switch try await embedWord(
                        word: a.word, anchorIndex: a.sentenceIndex, associations: a.associations,
                        sentences: sentences, usedIndexes: used, config: config) {
                    case .success(let newSentence):
                        replacements[a.sentenceIndex] = newSentence
                    case .skipped(let s):
                        skipped.append(s)
                        used.insert(a.sentenceIndex)
                    }
                }

                // 5. 回填
                var finalSentences = sentences
                for (idx, newSentence) in replacements {
                    finalSentences[idx] = newSentence
                }

                // 6. 局部衔接润色（替换点前后各 1 句）
                onProgress?(.thought(GenThought(
                    id: "smooth", kind: .polishing,
                    message: "正在衔接润色…", detail: nil, status: .running)))
                try Task.checkCancellation()
                finalSentences = await smoothAt(finalSentences, replaced: Set(replacements.keys))
                onProgress?(.thought(GenThought(
                    id: "smooth", kind: .polishing,
                    message: "衔接润色完成（\(replacements.count) 处）", detail: nil, status: .done)))
                body = Self.cleanArticle(finalSentences.joined(separator: " "))

                // 7. 整体自查（防写作过程自述/离题/劣化残留；complete 静默，失败保留原文）
                if !body.isEmpty {
                    onProgress?(.thought(GenThought(
                        id: "polish", kind: .polishing,
                        message: "正在整体润色…", detail: nil, status: .running)))
                    try Task.checkCancellation()
                    let polishBudget = bodyMaxTokens(maxWords: maxWords)
                    let polishPrompt = compressContext(
                        Self.polishPrompt(article: body), reservedForOutput: polishBudget,
                        protectedPrefix: Self.reviewInstructions)
                    if let polished = try? await client.complete(
                        prompt: polishPrompt, maxTokens: polishBudget, temperature: 0.3) {
                        let cleaned = AgenticPrompts.extractMarkedBody(polished)
                        if !cleaned.isEmpty { body = cleaned }
                    }
                    onProgress?(.thought(GenThought(
                        id: "polish", kind: .polishing,
                        message: "润色完成", detail: nil, status: .done)))
                }
            }
        }

        return try await makeArticle(
            body: body, targetLemmas: targetLemmas, surfaces: surfaces,
            skipped: skipped, strategy: strategy, constraints: constraints, graph: graph)
    }

    /// 联想 + 锚点选句：embedding 可用时优先语义余弦选锚（RAG 按需查询，阈值以下 skip）；
    /// 否则回退——草稿短 → 一次 LLM 选句；草稿长 → 联想(短) + 本地词面匹配。
    /// @ai: 带全文的 prompt 有 token 预算保护（本地模型上下文窗口小）；标 internal 便于测试。
    func resolveAnchors(
        words: [String], sentences: [String],
        wordLemmaMap: [String: EntityID], graph: GraphQueries
    ) async -> [AnchorAssignment] {
        // embedding 语义选锚（优先）：词库数据合成词向量 + 句子平均向量 → 余弦选最高分句
        if let provider = embeddingProvider {
            let composer = SemanticAnchorComposer(
                provider: provider, llm: client, graph: graph)
            let matcher = EmbeddingAnchorMatcher(composer: composer, provider: provider)
            let matches = await matcher.match(words: wordLemmaMap, sentences: sentences)
            // 只保留阈值以上的锚点（低于阈值 = 融不进去 → skip，不硬塞）
            let usable = matcher.deconflict(matches)
            let anchors = usable.compactMap { m -> AnchorAssignment? in
                guard m.sentenceIndex >= 0 else { return nil }
                // associations 用词库同义词（供改写参考，可选）
                let associations = synonymAssociations(for: m.word, lemmaId: wordLemmaMap[m.word], graph: graph)
                return AnchorAssignment(
                    word: m.word, sentenceIndex: m.sentenceIndex, associations: associations)
            }
            if !anchors.isEmpty { return anchors }
        }
        // 回退：LLM 联想 + 锚点选句
        let draft = sentences.joined(separator: " ")
        if Self.estimateTokens(draft) <= Self.anchorTokenBudget {
            let prompt = AgenticPrompts.anchorPrompt(sentences: sentences, words: words)
            let raw = try? await client.complete(prompt: prompt, maxTokens: 400, temperature: 0.2)
            return deconflict(
                AgenticPrompts.parseAnchors(raw, words: words, count: sentences.count),
                sentences: sentences)
        }
        // 长文降级：联想（短上下文）→ 本地词面匹配选句
        let assocRaw = try? await client.complete(
            prompt: AgenticPrompts.associationOnlyPrompt(words: words),
            maxTokens: 300, temperature: 0.2)
        let associations = AgenticPrompts.parseAssociations(assocRaw, words: words)
        return localAnchorMatch(words: words, associations: associations, sentences: sentences)
    }

    /// 锚点选句 prompt 的全文 token 预算（本地模型上下文保护；超限走本地匹配）。
    static let anchorTokenBudget = 900

    /// 从词库取目标词的 maps_to 同义词（逗号分隔），作为改写参考 associations。
    /// @ai: 复用现有词库数据，避免再调 LLM 联想；无同义词返回空串。
    private func synonymAssociations(for word: String, lemmaId: EntityID?, graph: GraphQueries) -> String {
        guard let lemmaId else { return "" }
        guard let detail = try? graph.lemmaDetail(lemmaId) else { return "" }
        let synonyms = detail.synonyms
            .compactMap(\.surfaceForm)
            .filter { !$0.isEmpty && $0.lowercased() != word.lowercased() }
        return synonyms.isEmpty ? "" : synonyms.joined(separator: ", ")
    }

    /// 粗略 token 估算（英文约 4 字符/token）。
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// LLM 选句结果占用去重：同句被多词选中 → 后到者顺延到下一个空闲句。
    private func deconflict(_ anchors: [AnchorAssignment], sentences: [String]) -> [AnchorAssignment] {
        var result = anchors
        var used = Set<Int>()
        for i in result.indices {
            if used.contains(result[i].sentenceIndex),
               let free = firstFreeAnchor(in: sentences, used: used) {
                result[i] = AnchorAssignment(
                    word: result[i].word, sentenceIndex: free, associations: result[i].associations)
            }
            used.insert(result[i].sentenceIndex)
        }
        return result
    }

    /// 长文锚点回退：联想 token 与句子归一化词元重叠打分，未占用最高分优先。
    private func localAnchorMatch(
        words: [String], associations: [String: String], sentences: [String]
    ) -> [AnchorAssignment] {
        var used = Set<Int>()
        var result: [AnchorAssignment] = []
        for word in words {
            let assocTokens = Set((associations[word] ?? "").split(separator: ",")
                .flatMap { $0.split(whereSeparator: { !$0.isLetter }) }
                .map { WordNormalizer.normalize(String($0)) }
                .filter { !$0.isEmpty })
            var best = (-1, -1)
            for (idx, sentence) in sentences.enumerated() where !used.contains(idx) {
                let sentenceTokens = Set(sentence.split(whereSeparator: { !$0.isLetter })
                    .map { WordNormalizer.normalize(String($0)) })
                let score = assocTokens.intersection(sentenceTokens).count
                if score > best.1 { best = (idx, score) }
            }
            let idx = best.0 >= 0 ? best.0 : (firstFreeAnchor(in: sentences, used: used) ?? 0)
            used.insert(idx)
            result.append(AnchorAssignment(
                word: word, sentenceIndex: idx, associations: associations[word] ?? ""))
        }
        return result
    }

    private func firstFreeAnchor(in sentences: [String], used: Set<Int>) -> Int? {
        for idx in sentences.indices where !used.contains(idx) && !sentences[idx].isEmpty {
            return idx
        }
        return nil
    }

    /// 局部衔接润色：对每个替换点前后各 1 句微调；失败静默保留。
    private func smoothAt(_ sentences: [String], replaced: Set<Int>) async -> [String] {
        var result = sentences
        for idx in replaced.sorted() {
            let prev = idx > 0 ? result[idx - 1] : nil
            let next = idx + 1 < result.count ? result[idx + 1] : nil
            let raw = try? await client.complete(
                prompt: AgenticPrompts.coherencePrompt(prev: prev, current: result[idx], next: next),
                maxTokens: 180, temperature: 0.2)
            let lines = AgenticPrompts.parseCoherence(raw, prev: prev, current: result[idx], next: next)
            if let p = lines[0], prev != nil { result[idx - 1] = p }
            result[idx] = lines[1] ?? result[idx]
            if let n = lines[2], next != nil { result[idx + 1] = n }
        }
        return result
    }

    /// 组装文章：跳过词结构化报告 → 规则兜底 → spans。
    private func makeArticle(
        body: String, targetLemmas: [EntityID], surfaces: [EntityID: String],
        skipped: [SkippedWord], strategy: GenStrategy,
        constraints: GenerationConstraints, graph: GraphQueries
    ) async throws -> GeneratedArticle {
        var finalBody = body
        var finalSkipped = skipped

        // 跳过词结构化报告（模型确认 + 原因；失败回退本地记录）
        if !finalSkipped.isEmpty {
            onProgress?(.thought(GenThought(
                id: "skipped", kind: .embedding,
                message: "未融入：\(finalSkipped.map(\.word).joined(separator: "、"))",
                detail: finalSkipped.map { "\($0.word)（\($0.reason)）" }.joined(separator: "\n"),
                status: .done)))
            try Task.checkCancellation()
            let raw = try? await client.complete(
                prompt: AgenticPrompts.skippedReportPrompt(skipped: finalSkipped),
                maxTokens: 200, temperature: 0.2)
            finalSkipped = AgenticPrompts.parseSkippedReport(raw, fallback: finalSkipped)
        }

        // 规则兜底：仍未嵌入的词 → 同义词替换（只替换已有同义词，不硬塞）
        let spans = Self.findTargetSpans(body: finalBody, surfaces: surfaces)
        let missingIds = targetLemmas.filter { !Set(spans.compactMap(\.lemmaId)).contains($0) }
        if !missingIds.isEmpty {
            let rule = RuleBasedGenerator()
            let rewritten = try await rule.generate(
                mode: .rewrite, sourceText: finalBody, targetLemmas: missingIds,
                constraints: constraints, graph: graph)
            if !rewritten.spans.isEmpty {
                finalBody = rewritten.body
            }
        }

        // 最终正文兜底：容错剥离标记（防变体标记漏进展示）
        finalBody = AgenticPrompts.extractMarkedBody(finalBody)
        // 最终校验：无正文（空 / 整篇写作自述）→ 生成失败，不落库
        guard !Self.isNoArticle(finalBody) else {
            throw ArticleGenError.noArticle
        }

        return GeneratedArticle(
            body: finalBody,
            spans: Self.findTargetSpans(body: finalBody, surfaces: surfaces),
            generatorId: Self.identifier, tier: Self.tier,
            plan: nil, strategy: strategy, skippedWords: finalSkipped)
    }
}
