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

    // MARK: - 输出约定标记

    func testExtractMarkedBody() {
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(
            "===ARTICLE_START===Hello world.===ARTICLE_END==="), "Hello world.")
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(
            "thinking\n===ARTICLE_START===Hello.===ARTICLE_END===trail"),
            "Hello.", "标记外内容应被丢弃")
    }

    func testExtractMarkedBodyFallsBackWhenNoMarkers() {
        let raw = "Plain article without markers."
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(raw), raw)
        XCTAssertEqual(AgenticPrompts.extractMarkedBody("===ARTICLE_START===半截"), "半截")
    }

    /// 回归：结束标记出现在开标记**之前**时不得崩溃。
    /// @ai: 旧实现独立查找 START/END，`start.upperBound > end.lowerBound` 会让
    ///      String 切片 trap（SIGTRAP 崩溃）。提示词里同时给了两个标记模板，
    ///      小模型回显指令（先复读 END）是常态，因此这条必须防住。
    func testExtractMarkedBodyEndMarkerBeforeStartDoesNotCrash() {
        let cases = [
            "===ARTICLE_END=== junk ===ARTICLE_START=== real content",
            "===ARTICLE_END===\n===ARTICLE_START===\nBody here.",
            "=== ARTICLE_END ===\n=== ARTICLE_START ===\nBody here.",
        ]
        for raw in cases {
            let out = AgenticPrompts.extractMarkedBody(raw)
            XCTAssertTrue(out.contains("real content") || out.contains("Body here."),
                          "应取开标记之后的内容，实际：\(out.prefix(40))")
        }
    }

    /// 回归：重复的结束标记不得崩溃，且取「第一个开标记之后」的内容。
    func testExtractMarkedBodyDuplicateEndMarkers() {
        let out = AgenticPrompts.extractMarkedBody(
            "===ARTICLE_START=== body ===ARTICLE_END=== trailing ===ARTICLE_END===")
        XCTAssertEqual(out, "body")
        // 开标记在中间、前面还有噪声结束标记
        let out2 = AgenticPrompts.extractMarkedBody(
            "note ===ARTICLE_END=== then ===ARTICLE_START=== good ===ARTICLE_END===")
        XCTAssertEqual(out2, "good")
    }

    // MARK: - 标记容错（小模型变体）

    func testExtractMarkedBodyTolerantVariants() {
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(
            "=== ARTICLE_START ===\nHello.\n=== ARTICLE_END ==="), "Hello.", "空格变体")
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(
            "<article_start>\nHello.\n<article_end>"), "Hello.", "尖括号变体")
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(
            "===ARTICLE_START===\r\nHello.\r\n===ARTICLE_END===\r\n"), "Hello.", "CRLF 变体")
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(
            "intro\n===ARTICLE_START===\nHello.\n===ARTICLE_END===\noutro"), "Hello.", "标记外内容丢弃")
    }

    func testExtractMarkedBodyKeepsNormalText() {
        let text = "The article started yesterday and ended today."
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(text), text, "正常句子不应被误剥")
    }

    func testStrippingMarkerLinesRemovesOnlyMarkerLines() {
        XCTAssertEqual(AgenticPrompts.strippingMarkerLines(
            "===ARTICLE_START===\nHello.\n<article_end>"), "Hello.")
        XCTAssertEqual(AgenticPrompts.strippingMarkerLines(
            "Hello world."), "Hello world.", "无标记行原样保留")
    }

    // MARK: - 前导大纲/计划回显剥离

    func testExtractMarkedBodyStripsLeadingOutline() {
        let raw = """
        - Paragraph 1: The craft of writing.
        - Paragraph 2: How to build vocabulary in context,
        - Paragraph 3: The nuance between synonyms and choosing the right word,

        A good writer must master both style and substance.
        """
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(raw),
                       "A good writer must master both style and substance.",
                       "无标记时也应剥离前导大纲回显")
    }

    func testExtractMarkedBodyStripsOutlineInsideMarkers() {
        let raw = """
        ===ARTICLE_START===
        Paragraph 1: Intro
        Paragraph 2: Body

        The real article begins here.
        ===ARTICLE_END===
        """
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(raw),
                       "The real article begins here.",
                       "标记内的大纲回显也应剥离")
    }

    func testStripLeadingJunkKeepsNormalText() {
        let text = "Part of the reason for this is the weather.\nThe rest is luck."
        XCTAssertEqual(AgenticPrompts.stripLeadingJunk(text), text,
                       "Part of the reason: 不应被误判为大纲")
    }

    func testExtractMarkedBodyStripsMetaPreamble() {
        let raw = """
        I'm not sure whether my draft is ready for publication — I need help with editing.

        A good writer must master both style and substance.
        """
        XCTAssertEqual(AgenticPrompts.extractMarkedBody(raw),
                       "A good writer must master both style and substance.",
                       "任务元句应被剥离")
    }

    func testPlainPromptContainsMarkerInstruction() {
        let p = GenStrategyPrompt.plainPrompt(theme: "科技", maxWords: 100)
        XCTAssertTrue(p.contains("===ARTICLE_START==="), "纯净草稿应要求标记")
        XCTAssertTrue(p.contains("===ARTICLE_END==="))
    }
}
