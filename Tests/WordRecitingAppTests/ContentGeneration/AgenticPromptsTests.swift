import XCTest
@testable import WordRecitingApp

/// Agentic 提示词模板与宽容解析。
final class AgenticPromptsTests: XCTestCase {

    // MARK: - 锚点选句

    func testAnchorPromptNumbersSentences() {
        let p = AgenticPrompts.anchorPrompt(
            sentences: ["A.", "B."], words: ["abandon"])
        XCTAssertTrue(p.contains("0: A."))
        XCTAssertTrue(p.contains("1: B."))
        XCTAssertTrue(p.contains("abandon"))
        XCTAssertTrue(p.contains("JSON"))
    }

    func testParseAnchorsValidJSON() {
        let raw = """
        {"abandon": {"index": 1, "associations": "give up, leave"}, "battle": {"index": 0, "associations": "fight"}}
        """
        let anchors = AgenticPrompts.parseAnchors(raw, words: ["abandon", "battle"], count: 3)
        XCTAssertEqual(anchors.count, 2)
        XCTAssertEqual(anchors[0].word, "abandon")
        XCTAssertEqual(anchors[0].sentenceIndex, 1)
        XCTAssertEqual(anchors[0].associations, "give up, leave")
        XCTAssertEqual(anchors[1].sentenceIndex, 0)
    }

    func testParseAnchorsGarbageFallsBackSequential() {
        let anchors = AgenticPrompts.parseAnchors("no json here", words: ["a", "b"], count: 2)
        XCTAssertEqual(anchors[0].sentenceIndex, 0)
        XCTAssertEqual(anchors[1].sentenceIndex, 1)
    }

    func testParseAnchorsOutOfRangeClamps() {
        let raw = "{\"a\": {\"index\": 99, \"associations\": \"x\"}}"
        let anchors = AgenticPrompts.parseAnchors(raw, words: ["a"], count: 2)
        XCTAssertEqual(anchors[0].sentenceIndex, 0, "越界应回退默认")
    }

    // MARK: - 专注改写

    func testFocusedRewritePromptContainsAllParts() {
        let p = AgenticPrompts.focusedRewritePrompt(
            sentence: "We go on.", word: "battle",
            associations: "fight, effort", feedback: nil)
        XCTAssertTrue(p.contains("We go on."))
        XCTAssertTrue(p.contains("battle"))
        XCTAssertTrue(p.contains("fight, effort"))
        XCTAssertTrue(p.contains("Output ONLY the rewritten sentence"))
    }

    func testFocusedRewritePromptAppendsFeedback() {
        let p = AgenticPrompts.focusedRewritePrompt(
            sentence: "We go on.", word: "battle",
            associations: "", feedback: ["目标词缺失", "意思改变"])
        XCTAssertTrue(p.contains("目标词缺失; 意思改变"))
    }

    // MARK: - 语义验证

    func testParseVerification() {
        XCTAssertTrue(AgenticPrompts.parseVerification("Yes, same."))
        XCTAssertFalse(AgenticPrompts.parseVerification("No, meaning changed."))
        XCTAssertTrue(AgenticPrompts.parseVerification("not sure"), "无法识别默认通过")
        XCTAssertTrue(AgenticPrompts.parseVerification(nil))
    }

    // MARK: - 衔接润色

    func testCoherencePromptAndParse() {
        let p = AgenticPrompts.coherencePrompt(
            prev: "P", current: "C", next: "N")
        XCTAssertTrue(p.contains("P"))
        XCTAssertTrue(p.contains("C"))
        XCTAssertTrue(p.contains("N"))
        let out = AgenticPrompts.parseCoherence(
            "P2\nC2\nN2", prev: "P", current: "C", next: "N")
        XCTAssertEqual(out, ["P2", "C2", "N2"])
    }

    func testParseCoherenceFallsBackOnGarbage() {
        let out = AgenticPrompts.parseCoherence(
            "only one line", prev: "P", current: "C", next: "N")
        XCTAssertEqual(out, ["P", "C", "N"], "解析失败回退原始三句")
    }

    // MARK: - 跳过报告

    func testSkippedReportPromptAndParse() {
        let skipped = [SkippedWord(word: "abandon", reason: "无法自然融入")]
        let p = AgenticPrompts.skippedReportPrompt(skipped: skipped)
        XCTAssertTrue(p.contains("abandon"))
        XCTAssertTrue(p.contains("JSON"))

        let raw = "[{\"word\": \"abandon\", \"reason\": \"no fit\"}]"
        let parsed = AgenticPrompts.parseSkippedReport(raw, fallback: skipped)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].word, "abandon")
        XCTAssertEqual(parsed[0].reason, "no fit")
    }

    func testParseSkippedReportFallsBack() {
        let skipped = [SkippedWord(word: "battle", reason: "x")]
        XCTAssertEqual(AgenticPrompts.parseSkippedReport(nil, fallback: skipped), skipped)
        XCTAssertEqual(AgenticPrompts.parseSkippedReport("garbage", fallback: skipped), skipped)
    }

    // MARK: - 长文降级：仅联想（短上下文）

    func testAssociationOnlyPromptAndParse() {
        let p = AgenticPrompts.associationOnlyPrompt(words: ["abandon"])
        XCTAssertTrue(p.contains("abandon"))
        XCTAssertTrue(p.contains("JSON"))
        XCTAssertFalse(p.contains("0:"), "联想 prompt 不应带全文句子编号")
        let parsed = AgenticPrompts.parseAssociations(
            "{\"abandon\": \"give up, leave\", \"battle\": \"fight\"}",
            words: ["abandon", "battle"])
        XCTAssertEqual(parsed["abandon"], "give up, leave")
        XCTAssertEqual(parsed["battle"], "fight")
        XCTAssertEqual(AgenticPrompts.parseAssociations("garbage", words: ["a"]), [:])
    }
}
