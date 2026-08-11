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
}
