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
        let raw = try await client.stream(
            prompt: GenStrategyPrompt.plainPrompt(theme: theme, maxWords: maxWords),
            maxTokens: maxTokens, temperature: temperature
        ) { [onProgress] token in
            onProgress?(.token(token))
        }
        var body = Self.cleanArticle(raw)

        var skipped: [SkippedWord] = []
        if !words.isEmpty, !body.isEmpty {
            // 2. 切句
            let sentences = SentenceSplitter.split(body)
            if sentences.isEmpty {
                skipped = words.map { SkippedWord(word: $0, reason: "草稿为空或无法断句") }
            } else {
                // 3. 联想 + 锚点（一次调用）
                onProgress?(.stage(.embedding))
                let anchors = await resolveAnchors(words: words, sentences: sentences)

                // 4. 逐词循环
                var replacements: [Int: String] = [:]
                var used = Set(anchors.map(\.sentenceIndex))
                for (i, a) in anchors.enumerated() {
                    onProgress?(.word(done: i, total: anchors.count, word: a.word))
                    switch await embedWord(
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
                finalSentences = await smoothAt(finalSentences, replaced: Set(replacements.keys))
                body = Self.cleanArticle(finalSentences.joined(separator: " "))
            }
        }

        return try await makeArticle(
            body: body, targetLemmas: targetLemmas, surfaces: surfaces,
            skipped: skipped, strategy: strategy, constraints: constraints, graph: graph)
    }

    /// 联想 + 锚点选句：草稿短 → 一次 LLM 选句；草稿长 → 联想(短) + 本地词面匹配。
    /// @ai: 带全文的 prompt 有 token 预算保护（本地模型上下文窗口小）；标 internal 便于测试。
    func resolveAnchors(words: [String], sentences: [String]) async -> [AnchorAssignment] {
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

        return GeneratedArticle(
            body: finalBody,
            spans: Self.findTargetSpans(body: finalBody, surfaces: surfaces),
            generatorId: Self.identifier, tier: Self.tier,
            plan: nil, strategy: strategy, skippedWords: finalSkipped)
    }
}
