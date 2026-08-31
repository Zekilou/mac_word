import XCTest
import GRDB
@testable import WordRecitingApp

/// LocalLLMGenerator 测试：mock LLMClient 验证 prompt 构造、文章清洗、span 扫描。
final class LocalLLMGeneratorTests: XCTestCase {

    /// 固定返回指定文本的 mock 客户端（可捕获收到的 prompt）。
    private struct MockClient: LLMClient {
        static let identifier = "mock"
        let response: String
        var onPrompt: @Sendable (String) -> Void = { _ in }
        func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
            onPrompt(prompt)
            return response
        }
    }

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
    }

    /// 准备词库：abandon / battle 两个 lemma。
    private func seedWords() throws -> [EntityID] {
        let now = Date()
        let ids = ["lemma-1", "lemma-2"]
        let words = ["abandon", "battle"]
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
                .init(id: "lemma-2", kind: .lemma, createdAt: now),
            ],
            textComponents: (0..<2).map { i in
                TextComponent(entityId: ids[i], textA: words[i], textB: nil, language: "en")
            },
            deckMetas: [DeckMetaComponent(
                entityId: "deck-1", name: "T", sourceKind: "csv",
                sourcePath: nil, importedAt: now)],
            edges: [],
            failures: [])
        try world.run(ImportSystem(), context: batch)
        return ids
    }

    // MARK: - 生成：LLM 输出被正确回传 + 目标词 spans 被扫描

    func testGenerateReturnsLLMArticleWithTargetSpans() async throws {
        let ids = try seedWords()

        let llmBody = "We should never abandon our dreams. The battle continues every day."
        let gen = LocalLLMGenerator(client: MockClient(response: llmBody))
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "科技",
            targetLemmas: ids,
            constraints: GenerationConstraints(),
            graph: graph)

        XCTAssertEqual(article.body, llmBody)
        XCTAssertEqual(article.generatorId, "local-llm")
        XCTAssertEqual(article.tier, .local)

        // spans 应命中两个目标词
        let spanLemmas = Set(article.spans.compactMap { $0.lemmaId })
        XCTAssertTrue(spanLemmas.contains(ids[0]))
        XCTAssertTrue(spanLemmas.contains(ids[1]))
        XCTAssertTrue(article.spans.allSatisfy { $0.isTarget })
    }

    // MARK: - fallback：LLM 未嵌目标词 → 规则替换把同义词换成目标词

    func testFallbackReplacesSynonymWhenLLMMissesTarget() async throws {
        let ids = try seedWords()

        // 词库增加一个 "give up" lemma，并建立 give up → abandon 的同义词边
        let now = Date()
        let giveUpId = "lemma-3"
        let addBatch = ImportBatch(
            deckId: "deck-1",
            nodes: [.init(id: giveUpId, kind: .lemma, createdAt: now)],
            textComponents: [TextComponent(entityId: giveUpId, textA: "give up", textB: nil, language: "en")],
            deckMetas: [],
            edges: [], failures: [])
        try world.run(ImportSystem(), context: addBatch)
        try world.run(SynonymSystem(), context: .add(
            from: ids[0], to: giveUpId, weight: 1.0, sourceType: "user"))

        // LLM 输出没包含 abandon，但包含了同义词 give up
        let llmBody = "We should never give up our dreams. The battle continues every day."
        let gen = LocalLLMGenerator(client: MockClient(response: llmBody))
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "科技",
            targetLemmas: ids,
            constraints: GenerationConstraints(),
            graph: graph)

        // fallback 后 abandon 应出现在正文（同义词 give up 被替换）
        XCTAssertTrue(article.body.lowercased().contains("abandon"),
                      "fallback 应把 give up 替换为 abandon，实际: \(article.body)")
        // 两个目标词都应命中 spans
        let spanLemmas = Set(article.spans.compactMap { $0.lemmaId })
        XCTAssertTrue(spanLemmas.contains(ids[0]), "abandon 应命中")
        XCTAssertTrue(spanLemmas.contains(ids[1]), "battle 应命中")
    }

    // MARK: - 改写模式同样可用

    func testRewriteModeUsesSourceInPrompt() async throws {
        let ids = try seedWords()
        let box = PromptListBox()
        let client = MockClient(response: "They will abandon the plan.") { prompt in
            box.values.append(prompt)
        }
        let gen = LocalLLMGenerator(client: client)
        _ = try await gen.generate(
            mode: .rewrite,
            sourceText: "They will abandon the plan.",
            targetLemmas: ids,
            constraints: GenerationConstraints(),
            graph: graph)
        // 首个 prompt 应为改写指令（含源文与目标词）；第二个为模型自查 prompt
        let first = try XCTUnwrap(box.values.first)
        XCTAssertTrue(first.contains("They will abandon the plan."))
        XCTAssertTrue(first.contains("abandon"))
        XCTAssertTrue(first.contains("battle"))
        XCTAssertEqual(box.values.count, 2, "应有一次生成 + 一次自查")
        XCTAssertTrue(box.values[1].contains("Review the English article below"),
                      "自查 prompt 应使用独立干净指令上下文")
    }

    // MARK: - 清洗：markdown 围栏被剥离

    func testCleanArticleStripsFences() {
        let raw = "```\nHello world.\n```"
        XCTAssertEqual(LocalLLMGenerator.cleanArticle(raw), "Hello world.")
    }

    // MARK: - 清洗：连续空行被折叠为段落空行（避免大片空白）

    func testCleanArticleCollapsesBlankLines() {
        let raw = "Para one.\n\n\n\n\nPara two.\r\n\r\n\r\nPara three."
        let cleaned = LocalLLMGenerator.cleanArticle(raw)
        XCTAssertFalse(cleaned.contains("\n\n\n"), "多余空行应被折叠: \(cleaned)")
        XCTAssertTrue(cleaned.contains("\n\n"), "段落之间保留一个空行")
        XCTAssertEqual(cleaned, "Para one.\n\nPara two.\n\nPara three.")
    }

    // MARK: - 模型自查：第二次 LLM 调用删掉释义句（含前置规划 pass）

    func testGenerateRunsModelSelfCheckPass() async throws {
        let ids = try seedWords()
        let box = PromptListBox()
        // 第 1 次策略；第 2 次规划；第 3 次生成返回含释义句的文章；第 4 次自查返回干净版本
        let client = SequenceMockClient(
            responses: [
                "STRATEGY: plan-embed\nWINDOW: whole\nFALLBACK: skip",
                "- abandon: used in intro\n- battle: used in body\n- Intro\n- Body\n- Conclusion",
                "The term 'abandon' means to leave. Technology changes our lives.",
                "Technology changes our lives.",
            ],
            onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "科技",
            targetLemmas: ids,
            constraints: GenerationConstraints(),
            graph: graph)
        // 四次调用：策略 + 规划 + 生成 + 自查
        XCTAssertEqual(box.values.count, 4)
        XCTAssertTrue(box.values[0].contains("STRATEGY"), "首个调用应为策略 pass")
        XCTAssertTrue(box.values[1].contains("planning"), "第二调用应为规划 prompt")
        XCTAssertTrue(box.values[2].contains("Writing plan to follow"),
                      "正文 prompt 应携带规划结果")
        XCTAssertTrue(box.values[3].contains("Review the English article below"),
                      "自查 prompt 应使用独立干净指令上下文")
        // 最终正文是自查后的干净版本
        XCTAssertFalse(article.body.contains("means to leave"),
                       "自查应删掉释义句，实际: \(article.body)")
        XCTAssertTrue(article.body.contains("Technology changes our lives"))
    }

    func testGenerateKeepsBodyWhenSelfCheckFails() async throws {
        let ids = try seedWords()
        // 策略、规划、生成正常；第 4 次（自查）抛错 → 应保留第一次生成的正文
        let client = SequenceMockClient(
            responses: [
                "STRATEGY: plan-embed\nWINDOW: whole\nFALLBACK: skip",
                "- abandon: intro\n- battle: body\n- Intro\n- Body",
                "We should not abandon our dreams.",
            ],
            failCall: 4,
            onPrompt: { _ in })
        let gen = LocalLLMGenerator(client: client)
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "科技",
            targetLemmas: ids,
            constraints: GenerationConstraints(),
            graph: graph)
        XCTAssertTrue(article.body.contains("We should not abandon our dreams"))
    }

    // MARK: - 无正文校验：整篇写作自述 → 生成失败，不落库

    func testGenerateThrowsWhenSelfCheckFindsNoArticle() async throws {
        let ids = try seedWords()
        // 生成返回"写作自述"；自查确认无正文 → 输出 NO_ARTICLE → 应抛错
        let client = SequenceMockClient(
            responses: [
                "STRATEGY: plan-embed\nWINDOW: whole\nFALLBACK: skip",
                "- abandon: intro\n- battle: body\n- Intro\n- Body",
                "The word 'esthetically' is the US spelling, I will use it.",
                "NO_ARTICLE",
            ],
            onPrompt: { _ in })
        let gen = LocalLLMGenerator(client: client)
        do {
            _ = try await gen.generate(
                mode: .generate, sourceText: "科技", targetLemmas: ids,
                constraints: GenerationConstraints(), graph: graph)
            XCTFail("整篇自述且自查确认无正文时应抛错")
        } catch let err as ArticleGenError {
            XCTAssertEqual(err, .noArticle)
        }
    }

    func testGenerateThrowsWhenBodyIsOnlySelfTalk() async throws {
        let ids = try seedWords()
        // 生成正文只有一句写作自述（含元注释短语），自查未返回有效正文 → 抛错不落库
        let client = SequenceMockClient(
            responses: [
                "STRATEGY: plan-embed\nWINDOW: whole\nFALLBACK: skip",
                "- abandon: intro\n- battle: body\n- Intro\n- Body",
                "The word 'esthetically' is the US spelling, I will use it.",
            ],
            failCall: 4,   // 自查失败 → 保留原正文 → 最终校验判无正文
            onPrompt: { _ in })
        let gen = LocalLLMGenerator(client: client)
        do {
            _ = try await gen.generate(
                mode: .generate, sourceText: "科技", targetLemmas: ids,
                constraints: GenerationConstraints(), graph: graph)
            XCTFail("正文只有写作自述时应抛错")
        } catch let err as ArticleGenError {
            XCTAssertEqual(err, .noArticle)
        }
    }

    func testIsNoArticleHeuristic() {
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(""))
        XCTAssertTrue(LocalLLMGenerator.isNoArticle("NO_ARTICLE"))
        // 哨兵变体（模型常加括号/混合大小写/尖括号）也应拦截，防漏网落库
        XCTAssertTrue(LocalLLMGenerator.isNoArticle("(No_article)"))
        XCTAssertTrue(LocalLLMGenerator.isNoArticle("<NO_ARTICLE>"))
        XCTAssertTrue(LocalLLMGenerator.isNoArticle("No Article"))
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "The word 'esthetically' is the US spelling, I will use it."))
        XCTAssertTrue(LocalLLMGenerator.isNoArticle("Let me re-read the thought process"))
        XCTAssertFalse(LocalLLMGenerator.isNoArticle(
            "We should never abandon our dreams. The battle continues every day."))
        XCTAssertFalse(LocalLLMGenerator.isNoArticle(
            "I will go to the market and buy some tea."),
            "普通短句不应误判为无正文")
    }

    // MARK: - 进度事件：阶段切换 + 流式 token

    func testGenerateEmitsProgressEvents() async throws {
        let ids = try seedWords()
        let box = ProgressBox()
        let gen = LocalLLMGenerator(
            client: MockClient(
                response: "We should not abandon our dreams. The battle continues every day."),
            onProgress: { box.events.append($0) })
        _ = try await gen.generate(
            mode: .generate,
            sourceText: "科技",
            targetLemmas: ids,
            constraints: GenerationConstraints(),
            graph: graph)
        // 阶段：策略 → 规划 → 生成 → 改写/自查
        let stages = box.events.compactMap { event -> GenStage? in
            if case .stage(let s) = event { return s }
            return nil
        }
        XCTAssertEqual(stages, [.strategy, .planning, .generating, .polishing])
        // token：仅生成与改写两轮流式（策略/规划 pass 用 complete，不产生流式 token）
        let tokens = box.events.compactMap { event -> String? in
            if case .token(let t) = event { return t }
            return nil
        }
        XCTAssertEqual(tokens.count, 2)
        XCTAssertTrue(tokens.joined().contains("abandon"))
    }

    // MARK: - 规划 pass：先联想词与主题关系、打草稿，再写正文

    func testPlanningPassFeedsPlanIntoBodyPrompt() async throws {
        let ids = try seedWords()
        let box = PromptListBox()
        let client = SequenceMockClient(
            responses: [
                "STRATEGY: plan-embed\nWINDOW: whole\nFALLBACK: skip",
                "- abandon: opens the article (people giving up old habits)\n- battle: body paragraph on effort\n- Intro\n- Body\n- Conclusion",
                "We should not abandon our dreams. The battle continues.",
            ],
            onPrompt: { box.values.append($0) })
        let gen = LocalLLMGenerator(client: client)
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "科技",
            targetLemmas: ids,
            constraints: GenerationConstraints(),
            graph: graph)
        // 策略 pass 在前；规划 prompt 要求对目标词聚类成子主题、识别逻辑连接词
        XCTAssertTrue(box.values[0].contains("STRATEGY"))
        XCTAssertTrue(box.values[1].contains("planning"))
        XCTAssertTrue(box.values[1].contains("abandon"))
        XCTAssertTrue(box.values[1].contains("battle"))
        XCTAssertTrue(box.values[1].contains("Cluster the words"))
        XCTAssertTrue(box.values[1].contains("CONNECTORS"))
        // 正文 prompt 携带规划结果，要求按计划用词
        XCTAssertTrue(box.values[2].contains("Writing plan to follow"))
        XCTAssertTrue(box.values[2].contains("abandon: opens the article"),
                      "正文 prompt 应包含规划内容，实际: \(box.values[2])")
        // 策略决策链回传（plan-embed 路径，思考链展示用）
        XCTAssertEqual(article.strategy?.mode, .planEmbed)
        XCTAssertEqual(article.strategy?.window, .whole)
        XCTAssertEqual(article.strategy?.fallback, .skip)
        XCTAssertEqual(article.plan, "- abandon: opens the article (people giving up old habits)\n- battle: body paragraph on effort\n- Intro\n- Body\n- Conclusion",
                       "规划产出应回传展示")
    }

    // MARK: - 提示词：允许省略融不进去的词（不硬塞）

    func testGeneratePromptAllowsOmission() {
        let prompt = LocalLLMGenerator.generatePrompt(
            theme: "科技", words: ["abandon", "battle"], maxWords: 100)
        XCTAssertTrue(prompt.contains("omit"), "提示词应允许省略: \(prompt)")
        XCTAssertTrue(prompt.contains("fit the"),
                      "提示词应说明融不进去就省略: \(prompt)")
        XCTAssertFalse(prompt.contains("MUST contain ALL"),
                       "不应再用绝对必含措辞")
        XCTAssertTrue(prompt.contains("STRICTLY FORBIDDEN"),
                      "应明确禁止释义句: \(prompt)")
    }

    // MARK: - 提示词：禁止回显计划与任务元评论（防正文混入大纲）

    func testPromptsForbidPlanEchoAndTaskMeta() {
        let gp = LocalLLMGenerator.generatePrompt(
            theme: "科技", words: ["abandon"], maxWords: 100,
            plan: "- Paragraph 1: Intro\n- Paragraph 2: Body")
        XCTAssertTrue(gp.contains("Do NOT repeat, restate, or quote the writing plan"),
                      "正文 prompt 应禁止回显计划")
        XCTAssertTrue(gp.contains("I am not sure whether my draft is ready"),
                      "正文 prompt 应禁止任务元句")
        XCTAssertTrue(gp.contains("NEVER narrate your own writing process"),
                      "正文 prompt 应禁止写作过程自述")

        let pp = LocalLLMGenerator.polishPrompt(article: "x")
        XCTAssertTrue(pp.contains("plan, outline, or numbered list of paragraphs"),
                      "自查 prompt 应要求删大纲块")
        XCTAssertTrue(pp.contains("talk about the text itself"),
                      "自查 prompt 应要求删任务元句")
        XCTAssertTrue(pp.contains("narrates the writer's own thinking"),
                      "自查 prompt 应要求删写作过程自述")
    }

    // MARK: - 目标词词形变化也能被命中（小写归一）

    func testFindTargetSpansCaseInsensitive() {
        let spans = LocalLLMGenerator.findTargetSpans(
            body: "Abandon the ship, then battle on.",
            surfaces: ["a": "abandon", "b": "battle"])
        XCTAssertEqual(spans.count, 2)
        XCTAssertTrue(spans.contains { $0.surfaceForm == "Abandon" && $0.lemmaId == "a" })
        XCTAssertTrue(spans.contains { $0.surfaceForm == "battle" && $0.lemmaId == "b" })
    }

    // MARK: - 空目标词：不崩溃，返回空 spans

    func testGenerateWithNoWordsStillWorks() async throws {
        let gen = LocalLLMGenerator(client: MockClient(response: "Just a sentence."))
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "主题",
            targetLemmas: [],
            constraints: GenerationConstraints(),
            graph: graph)
        XCTAssertFalse(article.body.isEmpty)
        XCTAssertTrue(article.spans.isEmpty)
    }

    // MARK: - 策略 pass：LLM 自选生成方案

    func testParseStrategyParsesAllFields() {
        let s = GenStrategyPrompt.parse(
            "STRATEGY: generate-rewrite\nWINDOW: sentence\nFALLBACK: retry")
        XCTAssertEqual(s.mode, .generateRewrite)
        XCTAssertEqual(s.window, .sentence)
        XCTAssertEqual(s.fallback, .retry)
    }

    func testParseStrategyDefaultsOnGarbage() {
        let s = GenStrategyPrompt.parse("no strategy here at all")
        XCTAssertEqual(s.mode, .planEmbed)
        XCTAssertEqual(s.window, .paragraph)
        XCTAssertEqual(s.fallback, .skip)
    }

    func testParseStrategyCaseInsensitive() {
        let s = GenStrategyPrompt.parse("strategy: plan-embed\nwindow: whole\nfallback: skip")
        XCTAssertEqual(s.mode, .planEmbed)
        XCTAssertEqual(s.window, .whole)
        XCTAssertEqual(s.fallback, .skip)
    }

    func testStrategyPromptContainsDecisionLines() {
        let p = GenStrategyPrompt.strategyPrompt(theme: "科技", words: ["abandon", "battle"])
        XCTAssertTrue(p.contains("STRATEGY"))
        XCTAssertTrue(p.contains("WINDOW"))
        XCTAssertTrue(p.contains("FALLBACK"))
        XCTAssertTrue(p.contains("generate-rewrite"))
    }

    // MARK: - 思考型模型走 RAG 逐词管线（草稿不喂词，按需嵌入）

    /// 思考型模型：不再全词单次（thinkingPrompt 已废除），改为草稿不喂词 → 逐词嵌入。
    /// 首个 prompt（草稿）不得包含目标词列表，符合"按需查询"。
    func testThinkingModeUsesDraftWithoutTargetWords() async throws {
        let ids = try seedWords()
        let box = PromptListBox()
        let client = MockClient(response: """
        ===ARTICLE_START===
        We should never abandon our dreams. The battle continues every day.
        ===ARTICLE_END===
        """) { prompt in
            box.values.append(prompt)
        }
        let gen = LocalLLMGenerator(client: client, isThinking: true)
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "科技",
            targetLemmas: ids,
            constraints: GenerationConstraints(),
            graph: graph)

        // 思考型走 generateViaRewrite：草稿 prompt 是 plainPrompt（不要求嵌入任何词）
        let first = try XCTUnwrap(box.values.first)
        XCTAssertTrue(first.contains("Write a natural, engaging English article"),
                      "草稿应为正常写作指令")
        XCTAssertFalse(first.contains("abandon, battle"),
                       "草稿不应把目标词列表塞进 prompt（按需查询）")
        XCTAssertFalse(first.contains("Work through the WHOLE task"),
                       "不应再走全词单次的 thinkingPrompt")
        // 最终正文应含目标词（逐词嵌入后）
        XCTAssertTrue(article.body.contains("abandon"))
        let spanLemmas = Set(article.spans.compactMap { $0.lemmaId })
        XCTAssertTrue(spanLemmas.contains(ids[0]))
    }

    /// 思考型模型：模型只输出写作自述/NO_ARTICLE → 不落库抛错。
    func testThinkingModeNoArticleThrows() async throws {
        let ids = try seedWords()
        let gen = LocalLLMGenerator(client: MockClient(response: "NO_ARTICLE"), isThinking: true)
        do {
            _ = try await gen.generate(
                mode: .generate,
                sourceText: "科技",
                targetLemmas: ids,
                constraints: GenerationConstraints(),
                graph: graph)
            XCTFail("应抛 ArticleGenError.noArticle")
        } catch ArticleGenError.noArticle {
            // 期望
        } catch {
            XCTFail("应为 noArticle，实际 \(error)")
        }
    }

    /// 空主题（词驱动）：普通模型 generatePrompt 同样不绑定主题。
    func testGeneratePromptEmptyThemeIsWordDriven() {
        let p = LocalLLMGenerator.generatePrompt(theme: "", words: ["abandon"], maxWords: 100)
        XCTAssertTrue(p.contains("words themselves shape the topic"))
        XCTAssertFalse(p.contains("about: general"))
    }

    /// 空主题（词驱动）：策略 prompt 指导选 plan-embed（词即主题，无需先写后改写）。
    func testStrategyPromptEmptyThemeGuidesPlanEmbed() {
        let p = GenStrategyPrompt.strategyPrompt(theme: "", words: ["abandon", "battle"])
        XCTAssertTrue(p.contains("(none — the target words ARE the topic)"))
        XCTAssertTrue(p.contains("always choose \"plan-embed\""))
    }

    /// 空主题（词驱动）：generate-rewrite 的草稿阶段让模型自由选材。
    func testPlainPromptEmptyThemeFreeChoice() {
        let p = GenStrategyPrompt.plainPrompt(theme: "", maxWords: 100)
        XCTAssertTrue(p.contains("topic of your choice"))
    }

}

/// Sendable 引用容器：@Sendable 闭包内安全写回测试捕获值。
private final class PromptListBox: @unchecked Sendable {
    var values: [String] = []
}

/// 进度事件收集容器。
private final class ProgressBox: @unchecked Sendable {
    var events: [GenProgress] = []
}

/// 按调用顺序依次返回响应的 mock 客户端（可让第 N 次调用抛错）。
private struct SequenceMockClient: LLMClient {
    static let identifier = "seq-mock"
    let responses: [String]
    /// 第几次调用时抛错（1 起计数）；nil = 全部成功。
    var failCall: Int? = nil
    var onPrompt: @Sendable (String) -> Void = { _ in }
    private let counter = CallCounterBox()

    func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        onPrompt(prompt)
        let call = counter.next()
        if call == failCall {
            throw LLMClientError.connection("mock failure")
        }
        return responses[min(call - 1, responses.count - 1)]
    }
}

/// 线程安全计数器（mock 顺序调用用）。
private final class CallCounterBox: @unchecked Sendable {
    var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
