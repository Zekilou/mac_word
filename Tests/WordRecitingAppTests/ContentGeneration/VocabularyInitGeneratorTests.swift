import XCTest
@testable import WordRecitingApp

final class VocabularyInitGeneratorTests: XCTestCase {

    private struct MockClient: LLMClient {
        static let identifier = "mock"
        let response: String
        var onPrompt: @Sendable (String) -> Void = { _ in }
        func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
            onPrompt(prompt)
            return response
        }
    }

    // MARK: - Prompt 分级

    func testIntroPromptUsesBasicWordConstraint() {
        let p = VocabularyInitGenerator.prompt(ease: .intro, topic: "your morning routine")
        XCTAssertTrue(p.contains("most common 500"))
        XCTAssertTrue(p.contains("No rare or academic words"))
        XCTAssertTrue(p.contains("your morning routine"), "prompt 应携带话题种子")
    }

    func testMediumPromptUsesEverydayVocabulary() {
        let p = VocabularyInitGenerator.prompt(ease: .medium, topic: "a trip to the market")
        XCTAssertTrue(p.contains("everyday"))
        XCTAssertTrue(p.contains("Avoid rare, technical, or academic vocabulary"))
        XCTAssertTrue(p.contains("a trip to the market"))
    }

    func testPromptsDifferByEase() {
        XCTAssertNotEqual(
            VocabularyInitGenerator.prompt(ease: .intro, topic: "t"),
            VocabularyInitGenerator.prompt(ease: .medium, topic: "t"))
    }

    // MARK: - 重试反馈（新词优先）

    func testPromptAppendsFeedback() {
        let p = VocabularyInitGenerator.prompt(
            ease: .medium, topic: "t", feedback: "Rewrite with different words.")
        XCTAssertTrue(p.contains("Rewrite with different words."))
        // 无反馈时不含
        XCTAssertFalse(VocabularyInitGenerator.prompt(ease: .medium, topic: "t")
            .contains("Rewrite with different words."))
    }

    func testFeedbackMessageListsKnownWords() {
        let msg = VocabularyInitGenerator.feedbackMessage(knownWords: ["apple", "battle"])
        XCTAssertTrue(msg.contains("apple"))
        XCTAssertTrue(msg.contains("battle"))
        XCTAssertTrue(msg.contains("DIFFERENT topic"))
        XCTAssertTrue(msg.contains("natural"), "反馈应强调保持自然，不硬塞词")
        XCTAssertFalse(msg.contains("too short"), "不短时不带长度反馈")
    }

    func testFeedbackMessageAddsLengthHintWhenTooShort() {
        let msg = VocabularyInitGenerator.feedbackMessage(
            knownWords: [], tooShort: true, contentCount: 3)
        XCTAssertTrue(msg.contains("too short"), "太短时引导写长")
        XCTAssertTrue(msg.contains("at least 100 words"))
        XCTAssertFalse(msg.contains("already knows"), "无已有词时不带换词反馈")
    }

    func testPromptMentionsMinimalLength() {
        XCTAssertTrue(VocabularyInitGenerator.prompt(ease: .medium, topic: "t")
            .contains("at least 100 words"), "medium prompt 应有明确总词数下限")
        XCTAssertTrue(VocabularyInitGenerator.prompt(ease: .intro, topic: "t")
            .contains("at least 100 words"), "intro prompt 应有明确总词数下限")
    }

    func testWordCountCountsAllWordsWithoutDedup() {
        XCTAssertEqual(VocabularyInitGenerator.wordCount(""), 0)
        XCTAssertEqual(VocabularyInitGenerator.wordCount("I am happy."), 3)
        XCTAssertEqual(
            VocabularyInitGenerator.wordCount(
                String(repeating: "The quiet farmer walks through the green valley every morning. ", count: 12)),
            120, "重复句按实际词数累计（不去重，每句 10 词）")
        XCTAssertEqual(VocabularyInitGenerator.wordCount("take up a hobby, don't stop!"), 6)
    }

    func testIsFunctionWord() {
        XCTAssertTrue(VocabularyInitGenerator.isFunctionWord("the"))
        XCTAssertTrue(VocabularyInitGenerator.isFunctionWord("is"))
        XCTAssertTrue(VocabularyInitGenerator.isFunctionWord("and"))
        XCTAssertFalse(VocabularyInitGenerator.isFunctionWord("abandon"))
        XCTAssertFalse(VocabularyInitGenerator.isFunctionWord("battle"))
    }

    func testGenerateWithFeedbackAppendsToPrompt() async throws {
        nonisolated(unsafe) var prompts: [String] = []
        let gen = VocabularyInitGenerator(client: MockClient(
            response: "I wake up early.",
            onPrompt: { prompts.append($0) }))
        _ = try await gen.generate(ease: .medium, topic: "a trip",
                                   feedback: "Note: too many known words.")
        XCTAssertEqual(prompts.count, 2, "慢思考：规划 pass + 正文各一次调用")
        XCTAssertTrue(prompts[0].contains("PLAN:"), "第一次调用是规划 pass")
        XCTAssertTrue(prompts[1].contains("Note: too many known words."))
        XCTAssertTrue(prompts[1].contains("a trip"), "反馈重试仍携带话题")
    }

    // MARK: - 慢思考：规划 pass

    func testPlanPassFeedsPlanIntoBodyPrompt() async throws {
        nonisolated(unsafe) var prompts: [String] = []
        let gen = VocabularyInitGenerator(client: MockClient(
            response: "PLAN: use walk, shop, friend; outline four short sentences.",
            onPrompt: { prompts.append($0) }))
        _ = try await gen.generate(ease: .medium, topic: "a trip")
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].contains("PLAN:"), "规划 prompt 要求 PLAN: 前缀")
        XCTAssertTrue(prompts[1].contains("Follow this plan"), "正文 prompt 携带计划")
        XCTAssertTrue(prompts[1].contains("walk, shop, friend"), "计划内容进入正文 prompt")
    }

    func testCleanPlanStripsPrefixOrNil() {
        XCTAssertEqual(VocabularyInitGenerator.cleanPlan("PLAN: use walk"), "use walk")
        XCTAssertEqual(VocabularyInitGenerator.cleanPlan("plan: use walk"), "use walk")
        XCTAssertNil(VocabularyInitGenerator.cleanPlan("no prefix here"), "无 PLAN: 前缀视为规划失败")
        XCTAssertNil(VocabularyInitGenerator.cleanPlan("PLAN:"), "空计划视为失败")
    }

    // MARK: - 清洗

    func testCleanStripsFencesAndCollapsesBlankLines() {
        let raw = "```\nI get up early.\n\n\n\nI eat breakfast.\n```"
        XCTAssertEqual(VocabularyInitGenerator.clean(raw),
                       "I get up early.\n\nI eat breakfast.")
    }

    // MARK: - 词元提取

    func testExtractWordsNormalizesAndDedups() {
        let words = VocabularyInitGenerator.extractWords("Abandon abandon battles battle.")
        XCTAssertEqual(words.map(\.lemma), ["abandon", "battle"])
        // 表面形式取首次出现的原文
        XCTAssertEqual(words.first?.surface, "Abandon")
    }

    func testExtractWordsSkipsSymbolsAndEmpty() {
        let words = VocabularyInitGenerator.extractWords("123 !!! [] get")
        XCTAssertEqual(words.map(\.lemma), ["get"])
    }

    func testExtractWordsKeepsPhraseTokens() {
        let words = VocabularyInitGenerator.extractWords("take up a hobby")
        XCTAssertEqual(words.map(\.lemma), ["take", "up", "a", "hobby"])
    }

    // MARK: - 生成

    func testGenerateReturnsCleanedParagraphAndWords() async throws {
        let gen = VocabularyInitGenerator(
            client: MockClient(response: "I wake up and make some tea."))
        let result = try await gen.generate(ease: .medium)
        XCTAssertEqual(result.paragraph, "I wake up and make some tea.")
        XCTAssertEqual(result.words.map(\.lemma), ["i", "wake", "up", "and", "make", "some", "tea"])
    }

    func testGenerateEmptyParagraphThrows() async throws {
        let gen = VocabularyInitGenerator(client: MockClient(response: "  ```  "))
        do {
            _ = try await gen.generate(ease: .intro)
            XCTFail("应抛出 emptyParagraph")
        } catch let err as InitGenerateError {
            XCTAssertEqual(err, .emptyParagraph)
        }
    }
}
