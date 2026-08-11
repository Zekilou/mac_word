import XCTest
@testable import WordRecitingApp

// MARK: - Mock 辅助（本文件内）

private final class PromptListBox: @unchecked Sendable {
    var values: [String] = []
}

private struct SeqClient: LLMClient {
    static let identifier = "seq"
    let responses: [String]
    var onPrompt: @Sendable (String) -> Void = { _ in }
    private let counter = CallCounterBox()
    func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        onPrompt(prompt)
        let call = counter.next()
        return responses[min(call - 1, responses.count - 1)]
    }
}

private final class CallCounterBox: @unchecked Sendable {
    var value = 0
    func next() -> Int { value += 1; return value }
}

/// Agentic 逐词融入：类型与管线测试（全部 mock，不跑真实模型）。
final class AgenticEmbeddingTests: XCTestCase {

    func testEmbeddingVerificationLabelsAndAllCases() {
        XCTAssertEqual(EmbeddingVerification.allCases.map(\.rawValue),
                       ["light", "standard", "strict"])
        XCTAssertFalse(EmbeddingVerification.light.label.isEmpty)
    }

    func testGenerationConstraintsDefaultsToStandard() {
        XCTAssertEqual(GenerationConstraints().embeddingVerification, .standard)
    }

    func testGeneratedArticleSkippedWordsDefaultsEmpty() {
        let article = GeneratedArticle(
            body: "x", spans: [], generatorId: "g", tier: .local)
        XCTAssertTrue(article.skippedWords.isEmpty)
    }

    // MARK: - 逐词循环（embedWord）

    func testEmbedWordSucceedsWhenWordAppears() async throws {
        let box = PromptListBox()
        let client = SeqClient(responses: [
            "The battle continues every day.",
            "Yes, they mean the same.",
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let result = await gen.embedWord(
            word: "battle", anchorIndex: 0, associations: "fight",
            sentences: ["We must keep going."], usedIndexes: [],
            config: .init())
        guard case .success(let sentence) = result else {
            return XCTFail("应成功嵌入，实际 \(result)")
        }
        XCTAssertTrue(sentence.contains("battle"))
        XCTAssertEqual(box.values.count, 2, "改写 + 语义验证各一次")
    }

    func testEmbedWordRetriesWithFeedbackWhenWordMissing() async throws {
        let box = PromptListBox()
        let client = SeqClient(responses: [
            "We must never give up.",
            "We must never abandon the fight.",
            "Yes.",
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let result = await gen.embedWord(
            word: "abandon", anchorIndex: 0, associations: "give up",
            sentences: ["We must keep going."], usedIndexes: [],
            config: .init(maxAttempts: 3))
        guard case .success = result else {
            return XCTFail("重试后应成功")
        }
        XCTAssertEqual(box.values.count, 3)
        XCTAssertTrue(box.values[1].contains("目标词缺失"), "第二次改写应带反馈原因")
    }

    func testEmbedWordSkipsAfterMaxAttempts() async throws {
        let client = SeqClient(responses: [
            "One.", "Two.", "Three.",  // 三次改写均不含词
        ])
        let gen = LocalLLMGenerator(client: client)
        let result = await gen.embedWord(
            word: "abandon", anchorIndex: 0, associations: "",
            sentences: ["Only sentence."], usedIndexes: [],
            config: .init(maxAttempts: 3, maxAnchorSwitches: 0))
        guard case .skipped(let skipped) = result else {
            return XCTFail("应跳过，实际 \(result)")
        }
        XCTAssertEqual(skipped.word, "abandon")
        XCTAssertFalse(skipped.reason.isEmpty)
    }

    func testEmbedWordSwitchesAnchorAfterFailures() async throws {
        let box = PromptListBox()
        let client = SeqClient(responses: [
            "A1.", "A2.", "A3.",  // 锚点 0 三次失败
            "The battle is here now.",  // 换锚点 1 成功
            "Yes.",
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let result = await gen.embedWord(
            word: "battle", anchorIndex: 0, associations: "",
            sentences: ["First sentence.", "Second sentence."],
            usedIndexes: [],
            config: .init(maxAttempts: 3, maxAnchorSwitches: 1))
        guard case .success(let sentence) = result else {
            return XCTFail("换锚点后应成功")
        }
        XCTAssertTrue(sentence.contains("battle"))
        XCTAssertEqual(box.values.count, 5)
    }

    func testEmbedWordRejectsDuplicateOutput() async throws {
        let box = PromptListBox()
        let client = SeqClient(responses: [
            "The battle rages on.",        // 尝试1：含词，语义验证判"否"→ 失败
            "No, the meaning changed.",
            "The battle rages on.",        // 尝试2：与尝试1文本相同 → 重复拦截（标准档已验证过，不再调验证）
            "The battle rages on every day now.",  // 尝试3：不同且含词 → 直接通过
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let result = await gen.embedWord(
            word: "battle", anchorIndex: 0, associations: "",
            sentences: ["We keep going."], usedIndexes: [],
            config: .init(maxAttempts: 3, maxAnchorSwitches: 0))
        guard case .success = result else {
            return XCTFail("去重后第三次应成功")
        }
        XCTAssertEqual(box.values.count, 4)
        XCTAssertTrue(box.values[2].contains("意思改变"), "尝试2 应带语义反馈")
        XCTAssertTrue(box.values[3].contains("重复输出"), "尝试3 应带重复反馈")
    }

    func testStrictVerificationChecksEveryAttempt() async throws {
        let box = PromptListBox()
        let client = SeqClient(responses: [
            "The battle is here now.",     // 尝试1：含词 → 严格验证
            "No.",
            "The battle is here again.",   // 尝试2：含词 → 再次严格验证
            "Yes.",
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let result = await gen.embedWord(
            word: "battle", anchorIndex: 0, associations: "",
            sentences: ["We go."], usedIndexes: [],
            config: .init(verification: .strict, maxAttempts: 3, maxAnchorSwitches: 0))
        guard case .success = result else {
            return XCTFail("严格档第二次验证通过应成功")
        }
        XCTAssertEqual(box.values.count, 4, "严格档每次尝试都调语义验证")
    }

    func testSemanticRejectionTriggersRetry() async throws {
        let client = SeqClient(responses: [
            "The battle is everywhere now.",
            "No, the meaning changed.",
            "The battle remains our main effort.",
            "Yes, they mean the same.",
        ])
        let gen = LocalLLMGenerator(client: client)
        let result = await gen.embedWord(
            word: "battle", anchorIndex: 0, associations: "",
            sentences: ["We keep going."], usedIndexes: [],
            config: .init(maxAttempts: 3, maxAnchorSwitches: 0))
        guard case .success = result else {
            return XCTFail("语义否决后重试应成功")
        }
    }

    func testLightVerificationSkipsSemanticCall() async throws {
        let box = PromptListBox()
        let client = SeqClient(responses: [
            "The battle is here.",
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let result = await gen.embedWord(
            word: "battle", anchorIndex: 0, associations: "",
            sentences: ["We go."], usedIndexes: [],
            config: .init(verification: .light, maxAttempts: 3, maxAnchorSwitches: 0))
        guard case .success = result else {
            return XCTFail("轻量档应直接通过")
        }
        XCTAssertEqual(box.values.count, 1, "轻量档不调语义验证")
    }

    // MARK: - 管线（generateViaRewrite）

    /// 完整管线：策略 → 纯净草稿 → 锚点 → 逐词嵌入 → 回填润色 → span。
    func testGenerateViaRewritePipelineEndToEnd() async throws {
        let appDB = try AppDatabase.inMemory()
        let world = World(database: appDB)
        let graph = world.graph
        let now = Date()
        let ids = ["lemma-1", "lemma-2"]
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
                .init(id: "lemma-2", kind: .lemma, createdAt: now),
            ],
            textComponents: [
                TextComponent(entityId: ids[0], textA: "abandon", textB: nil, language: "en"),
                TextComponent(entityId: ids[1], textA: "battle", textB: nil, language: "en"),
            ],
            deckMetas: [DeckMetaComponent(
                entityId: "deck-1", name: "T", sourceKind: "csv",
                sourcePath: nil, importedAt: now)],
            edges: [], failures: [])
        try world.run(ImportSystem(), context: batch)

        let box = PromptListBox()
        // 调用序列：
        // 1 策略 2 纯净草稿(stream→complete) 3 锚点选句
        // 4 abandon 改写 5 abandon 验证 6 battle 改写 7 battle 验证
        // 8 句0 衔接 9 句1 衔接
        let client = SeqClient(responses: [
            "STRATEGY: generate-rewrite\nWINDOW: sentence\nFALLBACK: skip",
            "A normal article about daily life. People wake up, work, and rest each day.",
            "{\"abandon\": {\"index\": 0, \"associations\": \"give up, leave\"}, \"battle\": {\"index\": 1, \"associations\": \"fight, effort\"}}",
            "We should never abandon our dreams.",
            "Yes, they mean the same.",
            "The battle continues every day.",
            "Yes, they mean the same.",
            "We should never abandon our dreams.\nThe battle continues every day.",
            "We should never abandon our dreams.\nThe battle continues every day.",
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let article = try await gen.generate(
            mode: .generate, sourceText: "科技", targetLemmas: ids,
            constraints: GenerationConstraints(), graph: graph)

        // 决策走 generate-rewrite；策略回传（首个调用为策略 pass，决策由末尾 strategy.mode 断言验证）
        XCTAssertTrue(box.values[0].contains("STRATEGY"), "首个调用应为策略 pass：\(box.values[0])")
        XCTAssertTrue(box.values[1].contains("Write a natural, engaging English article"),
                      "第一步应纯净草稿：\(box.values[1])")
        XCTAssertFalse(box.values[1].contains("abandon"), "草稿不应含目标词约束")
        // 专注改写 prompt 应单句 + 单词
        XCTAssertTrue(box.values[3].contains("Original sentence"), "第 4 次应为专注改写")
        // 回填润色调用
        XCTAssertTrue(box.values[7].contains("consecutive sentences"))
        // 最终正文含两词 + spans 命中 + 无跳过
        XCTAssertTrue(article.body.lowercased().contains("abandon"), "正文: \(article.body)")
        XCTAssertTrue(article.body.lowercased().contains("battle"), "正文: \(article.body)")
        let spanLemmas = Set(article.spans.compactMap { $0.lemmaId })
        XCTAssertTrue(spanLemmas.contains(ids[0]))
        XCTAssertTrue(spanLemmas.contains(ids[1]))
        XCTAssertTrue(article.skippedWords.isEmpty)
        XCTAssertEqual(article.strategy?.mode, .generateRewrite)
    }

    /// 全部词都融不进：换锚点仍失败 → 跳过 + 结构化报告。
    func testGenerateViaRewriteSkipsAndReports() async throws {
        let appDB = try AppDatabase.inMemory()
        let world = World(database: appDB)
        let graph = world.graph
        let now = Date()
        let ids = ["lemma-1", "lemma-2"]
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
                .init(id: "lemma-2", kind: .lemma, createdAt: now),
            ],
            textComponents: [
                TextComponent(entityId: ids[0], textA: "abandon", textB: nil, language: "en"),
                TextComponent(entityId: ids[1], textA: "battle", textB: nil, language: "en"),
            ],
            deckMetas: [DeckMetaComponent(
                entityId: "deck-1", name: "T", sourceKind: "csv",
                sourcePath: nil, importedAt: now)],
            edges: [], failures: [])
        try world.run(ImportSystem(), context: batch)

        let box = PromptListBox()
        // abandon 三次改写失败（无词）；used={0,1} 无空闲锚点 → 直接跳过
        // battle 成功；回填后衔接润色（句1）；最后跳过词结构化报告
        // 调用序列：
        // 1 策略 2 草稿 3 锚点
        // 4-6 abandon 改写(缺词×3)
        // 7 battle 改写 8 battle 验证
        // 9 句1 衔接润色
        // 10 跳过报告
        let client = SeqClient(responses: [
            "STRATEGY: generate-rewrite\nWINDOW: whole\nFALLBACK: retry",
            "A normal article about daily life. People wake up, work, and rest each day.",
            "{\"abandon\": {\"index\": 0, \"associations\": \"x\"}, \"battle\": {\"index\": 1, \"associations\": \"y\"}}",
            "Nothing to see here.",   // abandon 尝试1（缺词）
            "Still nothing here.",    // 尝试2
            "Again nothing.",         // 尝试3 → 跳过（无空闲锚点）
            "The battle continues every day.",
            "Yes.",
            "A normal article about daily life.\nThe battle continues every day.",  // 句1 衔接
            "[{\"word\": \"abandon\", \"reason\": \"no natural fit\"}]",
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let article = try await gen.generate(
            mode: .generate, sourceText: "科技", targetLemmas: ids,
            constraints: GenerationConstraints(), graph: graph)

        XCTAssertTrue(article.body.lowercased().contains("battle"))
        XCTAssertEqual(article.skippedWords.map(\.word), ["abandon"])
        XCTAssertEqual(article.skippedWords[0].reason, "no natural fit", "结构化报告应覆盖本地记录")
        let spanLemmas = Set(article.spans.compactMap { $0.lemmaId })
        XCTAssertTrue(spanLemmas.contains(ids[1]))
        XCTAssertFalse(spanLemmas.contains(ids[0]), "跳过的词不应命中 span")
        XCTAssertTrue(box.values[8].contains("consecutive sentences"), "回填后应衔接润色")
        XCTAssertTrue(box.values[9].contains("JSON"), "应调用跳过报告 prompt")
    }

    /// 长草稿（估算 > 预算）→ 不调用带全文的锚点 prompt，走联想(短) + 本地词面匹配。
    func testResolveAnchorsFallsBackToLocalMatchForLongDraft() async throws {
        let longSentences = (0..<60).map {
            "This is sentence number \($0) with some extra words to make it longer than before."
        }
        let longDraft = longSentences.joined(separator: " ")
        XCTAssertGreaterThan(LocalLLMGenerator.estimateTokens(longDraft),
                             LocalLLMGenerator.anchorTokenBudget,
                             "用例草稿必须超预算才能测到降级路径")
        let box = PromptListBox()
        let client = SeqClient(responses: [
            "{\"abandon\": \"give up, leave, desert\", \"battle\": \"fight, effort, struggle\"}",
        ], onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let anchors = await gen.resolveAnchors(words: ["abandon", "battle"], sentences: longSentences)
        XCTAssertEqual(anchors.count, 2)
        XCTAssertTrue(anchors.allSatisfy {
            $0.sentenceIndex >= 0 && $0.sentenceIndex < longSentences.count
        })
        XCTAssertFalse(box.values[0].contains("0:"), "长文不应调用带全文的锚点 prompt")
        XCTAssertTrue(box.values[0].contains("JSON"))
    }

    // MARK: - 思考事件类型

    func testGenThoughtFields() {
        let t = GenThought(
            id: "strategy", kind: .strategy,
            message: "策略：先写后改写", detail: nil, status: .done)
        XCTAssertEqual(t.kind, .strategy)
        XCTAssertEqual(t.status, .done)
        XCTAssertEqual(GenThought.Kind.allCases.count, 7)
    }
}
