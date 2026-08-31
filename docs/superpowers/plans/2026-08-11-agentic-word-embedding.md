# Agentic 逐词融入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 generate-rewrite 生成路径从「整篇一次改写」升级为「逐词 agentic 循环」（联想 → 锚点句 → 专注改写 → 验证 → 反馈重试 → 降级），让词在小模型上自然融入。

**Architecture:** 在 `LocalLLMGenerator` 上加两个 extension（管线编排 + 逐词循环），配一个纯函数提示词枚举；保留 strategy pass 二选一，`generate-rewrite` 分支改走新管线，plan-embed 不变。验证强度做成三档可配置（light/standard/strict）。跳过词由模型输出结构化 JSON，接入现有覆盖 ✗ chip 展示。

**Tech Stack:** Swift / SwiftUI / llama.cpp (LlamaSwift) / 无第三方新增依赖。

**规范（项目铁律）：**
- TDD：先写失败测试 → 实现 → 全绿。文件 ≤ 300 行（超限拆文件）。
- 测试只用 mock client（`MockClient` / `SequenceMockClient`），**禁止真实模型推理测试**（用户约定：大模型加载慢无结果）。
- 运行测试时跳过真实模型测试类：`swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests`。

---

## 文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/WordRecitingApp/AppTypes.swift` | 修改 | `EmbeddingVerification` 枚举 + `GenerationConstraints.embeddingVerification` |
| `Sources/WordRecitingApp/ContentGeneration/ContentGenerator.swift` | 修改 | `SkippedWord` + `GeneratedArticle.skippedWords` |
| `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift` | 修改 | `GenStage.embedding`、`GenProgress.word` |
| `Sources/WordRecitingApp/ContentGeneration/GenStrategy.swift` | 修改 | 删 `rewriteEmbedPrompt` / `retryEmbedPrompt` |
| `Sources/WordRecitingApp/ContentGeneration/SentenceSplitter.swift` | 新建 | 正则断句（缩写/引号保护） |
| `Sources/WordRecitingApp/ContentGeneration/AgenticPrompts.swift` | 新建 | 全部提示词 + 宽容解析 + `AnchorAssignment` |
| `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticLoop.swift` | 新建 | 逐词循环 + 评估 + 降级 |
| `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift` | 新建 | 管线编排（generateViaRewrite 新实现） |
| `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+RewriteStrategy.swift` | 删除 | 旧整篇改写（被新管线取代） |
| `Sources/WordRecitingApp/Settings/AppSettings.swift` | 修改 | `embeddingVerification` 持久化 |
| `Sources/WordRecitingApp/Settings/SettingsView.swift` | 修改 | 生成设置区加验证强度 Picker |
| `Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift` | 修改 | 进度映射 + `embedWordProgress` + `lastSkipped` + `skippedReason(for:)` + `applyProgress` |
| `Sources/WordRecitingApp/UI/Creation/GenerateView.swift` | 修改 | 进度条词级显示 + 覆盖 ✗ chip 原因 tooltip |
| `Tests/.../ContentGeneration/SentenceSplitterTests.swift` | 新建 | 断句测试 |
| `Tests/.../ContentGeneration/AgenticPromptsTests.swift` | 新建 | 提示词 + 解析测试 |
| `Tests/.../ContentGeneration/AgenticEmbeddingTests.swift` | 新建 | 逐词循环 + 管线测试（mock） |
| `Tests/.../Settings/AppSettingsTests.swift` | 修改 | 验证强度持久化 |
| `Tests/.../UI/GenerateViewModelTests.swift` | 修改 | 进度事件 + skippedReason |
| `Tests/.../ContentGeneration/LocalLLMGeneratorTests.swift` | 修改 | 删两个旧 generate-rewrite 测试 |

测试目录根：`Tests/WordRecitingAppTests`。

---

### Task 1: 基础类型与事件

**Files:**
- Modify: `Sources/WordRecitingApp/AppTypes.swift`（`GenerationConstraints` 上方加 `EmbeddingVerification`；`GenerationConstraints` 加字段）
- Modify: `Sources/WordRecitingApp/ContentGeneration/ContentGenerator.swift`（加 `SkippedWord` + `GeneratedArticle.skippedWords`）
- Modify: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift`（`GenStage` + `GenProgress`）
- Test: `Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift`（本任务只加类型断言）

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

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
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -5`
Expected: FAIL（类型不存在 / 属性缺失）。

- [ ] **Step 3: 实现类型**

`AppTypes.swift` 在 `struct GenerationConstraints` 前插入：

```swift
// MARK: - EmbeddingVerification（逐词融入验证强度）

/// 逐词融入的验证强度：按模型大小 / token 速率 / 云端 API 选择。
/// @ai: 轻量=本地慢速小模型；标准=通用；严格=云端 API / 大模型。
enum EmbeddingVerification: String, CaseIterable, Identifiable, Codable, Sendable {
    case light, standard, strict
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "轻量（本地小模型）"
        case .standard: return "标准（推荐）"
        case .strict: return "严格（云端/大模型）"
        }
    }
}
```

`GenerationConstraints` 加字段（`synonymDistance` 行后）：

```swift
    /// 逐词融入验证强度（generate-rewrite 路径）。nil=默认 standard。
    var embeddingVerification: EmbeddingVerification = .standard
```

`ContentGenerator.swift` 在 `GeneratedArticle` 前插入：

```swift
/// 未能自然融入的目标词（结构化报告：词 + 原因）。
struct SkippedWord: Sendable, Equatable {
    let word: String
    let reason: String
}
```

`GeneratedArticle` 加字段（`strategy` 行后）：

```swift
    /// 未能自然融入的目标词（模型结构化报告，仅 UI 展示，不落库）。
    var skippedWords: [SkippedWord] = []
```

`LocalLLMGenerator.swift` 的 `GenStage` 改为：

```swift
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
```

`GenProgress` 改为：

```swift
enum GenProgress: Sendable {
    case stage(GenStage)
    case token(String)
    /// 逐词融入进度：已处理（0 基）/总数/当前词。
    case word(done: Int, total: Int, word: String)
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -5`
Expected: 3 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/AppTypes.swift Sources/WordRecitingApp/ContentGeneration/ContentGenerator.swift Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift
git commit -m "feat(gen): add embedding verification level and skipped-word types"
```

---

### Task 2: 句子切分器 SentenceSplitter

**Files:**
- Create: `Sources/WordRecitingApp/ContentGeneration/SentenceSplitter.swift`
- Test: `Tests/WordRecitingAppTests/ContentGeneration/SentenceSplitterTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ContentGeneration/SentenceSplitterTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

/// 正则断句：缩写保护 + 引号内句号不切分。
final class SentenceSplitterTests: XCTestCase {

    func testSplitsOnPeriod() {
        let s = SentenceSplitter.split("Hello world. This is next.")
        XCTAssertEqual(s, ["Hello world.", "This is next."])
    }

    func testSplitsOnQuestionAndExclamation() {
        let s = SentenceSplitter.split("Are you ok? Yes! Great.")
        XCTAssertEqual(s, ["Are you ok?", "Yes!", "Great."])
    }

    func testKeepsAbbreviationTogether() {
        let s = SentenceSplitter.split("Dr. Smith works at U.S. labs. He is busy.")
        XCTAssertEqual(s, ["Dr. Smith works at U.S. labs.", "He is busy."])
    }

    func testKeepsDecimalAndSentenceTogether() {
        let s = SentenceSplitter.split("Pi is 3.14 roughly. That is fine.")
        XCTAssertEqual(s, ["Pi is 3.14 roughly.", "That is fine."])
    }

    func testKeepsQuoteEndingPeriodWithSentence() {
        let s = SentenceSplitter.split("He said \"go now.\" Then he left.")
        XCTAssertEqual(s, ["He said \"go now.\"", "Then he left."])
    }

    func testSingleSentence() {
        let s = SentenceSplitter.split("Just one sentence here.")
        XCTAssertEqual(s, ["Just one sentence here."])
    }

    func testEmptyReturnsEmpty() {
        XCTAssertTrue(SentenceSplitter.split("").isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SentenceSplitterTests 2>&1 | tail -5`
Expected: FAIL（类型不存在）。

- [ ] **Step 3: 实现**

创建 `Sources/WordRecitingApp/ContentGeneration/SentenceSplitter.swift`：

```swift
import Foundation

/// 正则断句：按 . ! ? 句末标点切分；保护常见缩写与引号内句号。
/// @ai: 纯规则实现，不引 spaCy；文章为模型生成，句式规范，本工具只做保守切分。
enum SentenceSplitter {

    /// 常见缩写（句号不作为断句点）。
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
        "e.g", "i.e", "a.m", "p.m", "u.s", "u.k", "ph.d", "no", "fig", "vol",
    ]

    /// 把文本切成句子数组（保留原文句子标点，首尾去空白）。
    static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var sentences: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if isEndPunct(c) {
                let nextIsBreak = (i + 1 >= chars.count) || chars[i + 1].isWhitespace
                    || isClosingPunct(chars[i + 1])
                if nextIsBreak && !endsWithAbbreviation(current) && !insideUnclosedQuote(current) {
                    // 吞掉紧随的闭合引号/右括号（归属当前句）
                    var j = i + 1
                    while j < chars.count && isClosingPunct(chars[j]) {
                        current.append(chars[j])
                        j += 1
                    }
                    let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { sentences.append(s) }
                    current = ""
                    i = j
                    continue
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    private static func isEndPunct(_ c: Character) -> Bool {
        c == "." || c == "!" || c == "?" || c == "。" || c == "！" || c == "？"
    }

    private static func isClosingPunct(_ c: Character) -> Bool {
        c == "\"" || c == "”" || c == "'" || c == ")" || c == "]"
    }

    /// 当前句以「缩写 + 句号」结尾（如 "Dr." / "e.g."），不切分。
    private static func endsWithAbbreviation(_ current: String) -> Bool {
        guard current.hasSuffix(".") else { return false }
        let body = String(current.dropLast())
        let word = body.split(separator: " ").last.map(String.init) ?? body
        let lower = word.lowercased()
        // 大写单字母（如 "T. S. Eliot" 的 T.）视为缩写
        if lower.count == 1, lower.allSatisfy(\.isLetter) { return true }
        return abbreviations.contains(lower)
    }

    /// 当前句内左引号数 > 右引号数 → 在引号内，句号不切分。
    private static func insideUnclosedQuote(_ current: String) -> Bool {
        let open = current.filter { $0 == "\"" || $0 == "“" }.count
        let close = current.filter { $0 == "\"" || $0 == "”" }.count
        return open > close
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SentenceSplitterTests 2>&1 | tail -5`
Expected: 7 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ContentGeneration/SentenceSplitter.swift Tests/WordRecitingAppTests/ContentGeneration/SentenceSplitterTests.swift
git commit -m "feat(gen): add sentence splitter for agentic embedding"
```

---

### Task 3: AgenticPrompts（提示词 + 宽容解析 + AnchorAssignment）

**Files:**
- Create: `Sources/WordRecitingApp/ContentGeneration/AgenticPrompts.swift`
- Test: `Tests/WordRecitingAppTests/ContentGeneration/AgenticPromptsTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ContentGeneration/AgenticPromptsTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgenticPromptsTests 2>&1 | tail -5`
Expected: FAIL（类型不存在）。

- [ ] **Step 3: 实现**

创建 `Sources/WordRecitingApp/ContentGeneration/AgenticPrompts.swift`：

```swift
import Foundation

/// 一个目标词的锚点分配（联想内容 + 锚点句索引）。
struct AnchorAssignment: Sendable {
    let word: String
    let sentenceIndex: Int
    let associations: String
}

/// Agentic 逐词融入的提示词模板与宽容解析。
/// @ai: 模型输出固定结构（JSON/固定行），解析失败一律规则回退，不因 JSON 不稳中断。
enum AgenticPrompts {

    // MARK: - 联想 + 锚点选句（一次调用）

    static func anchorPrompt(sentences: [String], words: [String]) -> String {
        let numbered = sentences.enumerated()
            .map { "\($0.offset): \($0.element)" }
            .joined(separator: "\n")
        let wordList = words.joined(separator: ", ")
        return """
        You are embedding vocabulary into an existing English article.
        The article, split into numbered sentences:

        \(numbered)

        Target words: \(wordList)

        For each target word:
        1. ASSOCIATIONS: list 3-5 related images, scenes, or synonyms (comma separated).
        2. Pick the sentence number whose meaning is the best natural home for the word.

        Output ONLY a JSON object, one entry per word, no explanation:
        {"word": {"index": N, "associations": "a, b, c"}, ...}
        """
    }

    /// 宽容解析锚点选句 → [AnchorAssignment]；JSON 无效/词缺失/越界回退默认。
    static func parseAnchors(_ raw: String?, words: [String], count: Int) -> [AnchorAssignment] {
        guard count > 0 else { return [] }
        guard let raw, let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else {
            return defaultAssignments(words: words, count: count)
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return defaultAssignments(words: words, count: count)
        }
        var result: [AnchorAssignment] = []
        for word in words {
            if let entry = obj[word],
               let idx = entry["index"] as? Int,
               idx >= 0, idx < count,
               let assoc = entry["associations"] as? String {
                result.append(AnchorAssignment(word: word, sentenceIndex: idx, associations: assoc))
            } else {
                result.append(AnchorAssignment(word: word, sentenceIndex: 0, associations: ""))
            }
        }
        return result
    }

    private static func defaultAssignments(words: [String], count: Int) -> [AnchorAssignment] {
        words.enumerated().map { i, w in
            AnchorAssignment(word: w, sentenceIndex: min(i, count - 1), associations: "")
        }
    }

    // MARK: - 专注改写

    static func focusedRewritePrompt(
        sentence: String, word: String, associations: String, feedback: [String]?
    ) -> String {
        var prompt = """
        Original sentence: \(sentence)
        Word to include: "\(word)"
        \(associations.isEmpty ? "" : "Word associations: \(associations)\n")
        Rewrite the sentence so that "\(word)" appears naturally. Keep the meaning exactly the same.
        You may use an inflected form (e.g. "abandoned", "battles") if it reads better.
        Do NOT define or explain the word, and do NOT add extra sentences.
        Output ONLY the rewritten sentence.
        """
        if let feedback, !feedback.isEmpty {
            prompt += """

            The previous attempt(s) were rejected for: \(feedback.joined(separator: "; ")).
            Try again, fixing those problems. Output ONLY the rewritten sentence.
            """
        }
        return prompt
    }

    // MARK: - 语义保真验证

    static func verificationPrompt(original: String, rewritten: String) -> String {
        """
        Original sentence: \(original)
        Rewritten sentence: \(rewritten)
        Do these two sentences mean the same thing? Answer ONLY "Yes" or "No", then one short reason.
        """
    }

    /// 解析验证输出：no 开头 → false；其余（含无法识别）→ true（存在性已由规则把关，不过度拒绝）。
    static func parseVerification(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !lower.hasPrefix("no")
    }

    // MARK: - 局部衔接润色

    static func coherencePrompt(prev: String?, current: String, next: String?) -> String {
        """
        Three consecutive sentences from an article:
        Previous: \(prev ?? "(none)")
        Current: \(current)
        Next: \(next ?? "(none)")
        Smooth the connections between them. You may adjust only transition words and pronouns.
        Do NOT change each sentence's main meaning.
        Output ONLY the three revised sentences, one per line, in order.
        """
    }

    /// 解析润色输出（期望 3 行）；行数不足/无法解析回退原始三句。
    static func parseCoherence(_ raw: String?, prev: String?, current: String, next: String?) -> [String?] {
        guard let raw else { return [prev, current, next] }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if lines.count >= 3 {
            return [lines[0], lines[1], lines[2]]
        }
        if lines.count == 2, prev == nil {
            return [nil, lines[0], lines[1]]
        }
        return [prev, current, next]
    }

    // MARK: - 跳过词结构化报告

    static func skippedReportPrompt(skipped: [SkippedWord]) -> String {
        let list = skipped.map { "- \($0.word) (\($0.reason))" }.joined(separator: "\n")
        return """
        The following target words could not be naturally included in the article:
        \(list)
        Output ONLY a JSON array confirming each word and a short reason:
        [{"word": "...", "reason": "..."}, ...]
        """
    }

    /// 解析跳过报告；失败回退本地记录。
    static func parseSkippedReport(_ raw: String?, fallback: [SkippedWord]) -> [SkippedWord] {
        guard let raw, let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end else {
            return fallback
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return fallback
        }
        let parsed = arr.compactMap { entry -> SkippedWord? in
            guard let word = entry["word"], !word.isEmpty else { return nil }
            return SkippedWord(word: word, reason: entry["reason"] ?? "未能自然融入")
        }
        return parsed.isEmpty ? fallback : parsed
    }

    // MARK: - 长文降级：仅联想（短上下文，本地模型窗口保护）

    /// 只让模型给每个词联想语义场（不包含全文句子，context 极短）。
    static func associationOnlyPrompt(words: [String]) -> String {
        """
        For each word below, list 3-5 related images, scenes, or synonyms (comma separated).
        Output ONLY a JSON object:
        {"word": "a, b, c", ...}
        Words: \(words.joined(separator: ", "))
        """
    }

    /// 解析联想输出；JSON 无效或词缺失回退空字符串。
    static func parseAssociations(_ raw: String?, words: [String]) -> [String: String] {
        guard let raw, let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return [:] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return words.reduce(into: [:]) { acc, w in
            if let v = obj[w], !v.isEmpty { acc[w] = v }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AgenticPromptsTests 2>&1 | tail -5`
Expected: 13 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ContentGeneration/AgenticPrompts.swift Tests/WordRecitingAppTests/ContentGeneration/AgenticPromptsTests.swift
git commit -m "feat(gen): add agentic prompts with tolerant parsing"
```

---

### Task 4: 逐词循环 + 评估 + 降级（AgenticLoop）

**Files:**
- Create: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticLoop.swift`
- Test: `Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift`（追加）

- [ ] **Step 1: 写失败测试**

在 `AgenticEmbeddingTests.swift` 追加（文件顶部加 mock 辅助）：

```swift
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
```

追加循环测试：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -5`
Expected: FAIL（embedWord / EmbedConfig 不存在）。

- [ ] **Step 3: 实现**

创建 `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticLoop.swift`：

```swift
import Foundation

/// Agentic 逐词融入的评估与循环（extension）。
/// @ai: 每个词独立闭环：专注改写 → 评估（存在性/语义/重复）→ 反馈重试 → 换锚点 → 跳过。
extension LocalLLMGenerator {

    /// 一个词融入的最终产物。
    enum EmbedResult: Sendable {
        case success(String)
        case skipped(SkippedWord)
    }

    /// 评估器与循环配置。
    struct EmbedConfig: Sendable {
        var verification: EmbeddingVerification = .standard
        var maxAttempts: Int = 3
        var maxAnchorSwitches: Int = 1
    }

    /// 一次尝试的评估结论。
    enum Verdict: Sendable {
        case pass
        case fail([String])
    }

    /// 对一个词执行专注改写循环：K 次尝试 → 换锚点（M 次）→ 跳过。
    func embedWord(
        word: String, anchorIndex: Int, associations: String,
        sentences: [String], usedIndexes: Set<Int>, config: EmbedConfig
    ) async -> EmbedResult {
        let history = AttemptHistory()
        var anchor = anchorIndex
        var anchorSwitches = 0
        while true {
            guard sentences.indices.contains(anchor) else {
                return .skipped(SkippedWord(word: word, reason: "草稿为空或锚点句缺失"))
            }
            let sentence = sentences[anchor]
            var attempts = 0
            var lastFeedback: [String]?
            while attempts < config.maxAttempts {
                let prompt = AgenticPrompts.focusedRewritePrompt(
                    sentence: sentence, word: word,
                    associations: associations, feedback: lastFeedback)
                let raw = try? await client.complete(
                    prompt: prompt, maxTokens: 120, temperature: 0.5)
                let rewritten = (raw.map { Self.cleanArticle($0) } ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                attempts += 1
                if rewritten.isEmpty {
                    lastFeedback = ["空输出"]
                    continue
                }
                switch await evaluateRewritten(
                    original: sentence, rewritten: rewritten, word: word,
                    history: history, config: config) {
                case .pass:
                    return .success(rewritten)
                case .fail(let reasons):
                    lastFeedback = reasons
                }
            }
            if anchorSwitches < config.maxAnchorSwitches,
               let next = nextFreeAnchor(after: anchor, in: sentences, used: usedIndexes) {
                anchor = next
                anchorSwitches += 1
                continue
            }
            return .skipped(SkippedWord(
                word: word, reason: "\(config.maxAttempts) 次尝试后仍无法自然融入"))
        }
    }

    /// 评估一句改写：存在性（规则）+ 语义保真（LLM，按强度）+ 重复检测（规则）。
    func evaluateRewritten(
        original: String, rewritten: String, word: String,
        history: AttemptHistory, config: EmbedConfig
    ) async -> Verdict {
        var reasons: [String] = []
        let contains = Self.containsWord(rewritten, word: word)
        if !contains { reasons.append("目标词缺失") }
        let duplicate = history.isDuplicate(rewritten)
        if duplicate { reasons.append("重复输出") }
        history.append(rewritten)

        let shouldVerify: Bool
        switch config.verification {
        case .light: shouldVerify = false
        case .standard: shouldVerify = !history.semanticChecked
        case .strict: shouldVerify = true
        }
        if contains && !duplicate && shouldVerify {
            history.markSemanticChecked()
            let raw = try? await client.complete(
                prompt: AgenticPrompts.verificationPrompt(original: original, rewritten: rewritten),
                maxTokens: 60, temperature: 0)
            if !AgenticPrompts.parseVerification(raw) {
                reasons.append("意思改变")
            }
        }
        return reasons.isEmpty ? .pass : .fail(reasons)
    }

    /// 目标词是否出现在句中（WordNormalizer 归一化匹配，容忍屈折变化）。
    static func containsWord(_ sentence: String, word: String) -> Bool {
        let target = WordNormalizer.normalize(word)
        guard !target.isEmpty else {
            return sentence.lowercased().contains(word.lowercased())
        }
        let tokens = sentence.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .map { WordNormalizer.normalize(String($0)) }
        return tokens.contains(target)
    }

    /// 锚点后第一个未被占用的句索引（循环找，找不到返回 nil）。
    private func nextFreeAnchor(after idx: Int, in sentences: [String], used: Set<Int>) -> Int? {
        guard !sentences.isEmpty else { return nil }
        for offset in 1...sentences.count {
            let candidate = (idx + offset) % sentences.count
            if !used.contains(candidate) && !sentences[candidate].isEmpty {
                return candidate
            }
        }
        return nil
    }
}

/// 循环内历史：已尝试句子（重复检测）+ 语义是否已判定。
final class AttemptHistory: @unchecked Sendable {
    private(set) var attempts: [String] = []
    private(set) var semanticChecked = false
    func append(_ s: String) { attempts.append(s) }
    func markSemanticChecked() { semanticChecked = true }
    /// 与历史任一尝试归一化相似度 > 0.9 视为重复。
    func isDuplicate(_ s: String) -> Bool {
        attempts.contains { Self.similarity($0, s) > 0.9 }
    }
    /// 归一化文本相似度（小写去空白 + 字符级 Levenshtein）。
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalized(a), y = normalized(b)
        if x == y { return 1.0 }
        guard !x.isEmpty, !y.isEmpty else { return 0.0 }
        let dist = levenshtein(Array(x), Array(y))
        return 1.0 - Double(dist) / Double(max(x.count, y.count))
    }
    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let tmp = dp[j]
                dp[j] = min(dp[j] + 1, dp[j - 1] + 1,
                            prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return dp[b.count]
    }
}
```

（`complete` 返回 `String` 非 Optional，`raw.map { Self.cleanArticle($0) } ?? ""` 即为正确写法。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -5`
Expected: 全部通过（含 Task 1 的 3 个类型测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticLoop.swift Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift
git commit -m "feat(gen): add per-word agentic loop with verification and fallback"
```

---

### Task 5: 管线编排（generateViaRewrite 新实现）

**Files:**
- Create: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift`
- Delete: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+RewriteStrategy.swift`
- Modify: `Sources/WordRecitingApp/ContentGeneration/GenStrategy.swift`（删 rewriteEmbedPrompt / retryEmbedPrompt）
- Test: `Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift`（追加管线测试）
- Modify: `Tests/WordRecitingAppTests/ContentGeneration/LocalLLMGeneratorTests.swift`（删两个旧 generate-rewrite 测试）

- [ ] **Step 1: 写失败测试**

在 `AgenticEmbeddingTests.swift` 追加管线端到端测试：

```swift
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

        // 决策走 generate-rewrite；策略回传
        XCTAssertEqual(box.values[0], "STRATEGY: generate-rewrite\nWINDOW: sentence\nFALLBACK: skip")
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
```

同时删除 `LocalLLMGeneratorTests.swift` 中的两个旧测试方法：
- `testGenerateRewriteFlow`（含其后注释行 `// 正文 = 改写输出，spans 命中两个目标词` 与断言、策略回传断言）
- `testRewriteFallbackRetryOnceWithMissingWords`

（删除时保留文件中其余测试；删除后该文件仍编译。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -5`
Expected: FAIL（generateViaRewrite 新管线不存在 → 走旧逻辑，旧测试已被删除导致行为不符）。本任务先改代码再验证亦可：先完成 Step 3 实现再跑。

- [ ] **Step 3: 实现**

创建 `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift`：

```swift
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
```

删除 `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+RewriteStrategy.swift`（`DeleteFile`）。

`GenStrategy.swift` 删除 `rewriteEmbedPrompt` 与 `retryEmbedPrompt` 两个函数（`plainPrompt` 与 `strategyPrompt`、`parse` 保留）。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -5`
Expected: 全部通过。再跑受影响旧测试：

Run: `swift test --filter LocalLLMGeneratorTests 2>&1 | tail -5`
Expected: 通过（旧 generate-rewrite 测试已删除，其余 plan-embed 测试不受影响）。

- [ ] **Step 5: Commit**

```bash
git add -A
git rm Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+RewriteStrategy.swift
git commit -m "feat(gen): replace whole-article rewrite with agentic per-word pipeline"
```

---

### Task 6: 设置项 embeddingVerification

**Files:**
- Modify: `Sources/WordRecitingApp/Settings/AppSettings.swift`
- Modify: `Sources/WordRecitingApp/Settings/SettingsView.swift`
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift`（runGenerate 里把设置写入 constraints）
- Modify: `Tests/WordRecitingAppTests/Settings/AppSettingsTests.swift`

- [ ] **Step 1: 写失败测试**

`AppSettingsTests.swift` 追加：

```swift
    // MARK: - 逐词融入验证强度

    @MainActor func testEmbeddingVerificationPersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.embeddingVerification, .standard, "默认应为 standard")
        settings.embeddingVerification = .strict
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.embeddingVerification, .strict)
    }
```

（先看现有 `AppSettingsTests` 的 setUp 里 `defaults` 如何注入；若没有，参考 GenerateViewModelTests 用 `UserDefaults(suiteName:)` 隔离。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AppSettingsTests 2>&1 | tail -5`
Expected: FAIL（属性不存在）。

- [ ] **Step 3: 实现**

`AppSettings.swift`：`Key` 加 `static let embeddingVerification = "settings.embeddingVerification"`，并加属性：

```swift
    // MARK: - 逐词融入验证强度

    /// generate-rewrite 逐词融入的验证强度（light/standard/strict）。
    var embeddingVerification: EmbeddingVerification {
        get {
            guard let raw = defaults.string(forKey: Key.embeddingVerification),
                  let level = EmbeddingVerification(rawValue: raw) else { return .standard }
            return level
        }
        set { defaults.set(newValue.rawValue, forKey: Key.embeddingVerification) }
    }
```

`reset()` 的 key 列表加 `Key.embeddingVerification`。

`SettingsView.swift` 的 `generationSection` 内（`if vm.settings.generatorTier == .remote { remoteConfig }` 之后）追加：

```swift
                Divider()
                Text("逐词融入验证强度").font(.caption).foregroundStyle(.secondary)
                Picker("验证强度", selection: Binding(
                    get: { vm.settings.embeddingVerification },
                    set: { vm.settings.embeddingVerification = $0 }
                )) {
                    ForEach(EmbeddingVerification.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("轻量适合本地小模型（少调用）；严格适合云端 API / 大模型。")
                    .font(.caption2).foregroundStyle(.tertiary)
```

`GenerateViewModel.swift` 的 `runGenerate()` 内（`var c = constraints` 后、`c.topic = topic` 旁）追加：

```swift
            c.embeddingVerification = settings.embeddingVerification
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AppSettingsTests 2>&1 | tail -5`
Expected: PASS。再 build 确认 UI 编译：`swift build 2>&1 | tail -5` → Build complete，0 warning。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/Settings/AppSettings.swift Sources/WordRecitingApp/Settings/SettingsView.swift Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift Tests/WordRecitingAppTests/Settings/AppSettingsTests.swift
git commit -m "feat(settings): add embedding verification level config"
```

---

### Task 7: 进度展示 + 覆盖原因

**Files:**
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateView.swift`
- Modify: `Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift`

- [ ] **Step 1: 写失败测试**

`GenerateViewModelTests.swift` 追加：

```swift
    // MARK: - Agentic 进度与跳过词

    @MainActor func testApplyProgressEmbeddingStageAndWord() {
        let vm = makeVM()
        vm.applyProgress(.stage(.embedding))
        XCTAssertEqual(vm.genStage, .embedding)
        vm.applyProgress(.word(done: 2, total: 5, word: "battle"))
        XCTAssertEqual(vm.embedWordProgress, EmbedWordProgress(done: 2, total: 5, word: "battle"))
    }

    @MainActor func testSkippedReasonLookup() {
        let vm = makeVM()
        vm.lastSkipped = [SkippedWord(word: "abandon", reason: "no fit")]
        XCTAssertEqual(vm.skippedReason(for: "abandon"), "no fit")
        XCTAssertNil(vm.skippedReason(for: "battle"))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -5`
Expected: FAIL（`applyProgress` / `embedWordProgress` / `lastSkipped` / `skippedReason(for:)` / `EmbedWordProgress` 不存在）。

- [ ] **Step 3: 实现**

`GenerateViewModel.swift`：

- 顶部加结构体（`WordCoverage` 前）：

```swift
/// 逐词融入进度（供进度条下方显示「3/10 battle」）。
struct EmbedWordProgress: Equatable, Sendable {
    let done: Int
    let total: Int
    let word: String
}
```

- 输出区加属性（`coverage` 旁）：

```swift
    /// 逐词融入进度（generate-rewrite 时实时更新）。
    var embedWordProgress: EmbedWordProgress?
    /// 未能自然融入的目标词（结构化报告，UI 覆盖 ✗ chip 悬停显示原因）。
    var lastSkipped: [SkippedWord] = []
```

- `progressHandler` 闭包改为调用内部方法：

```swift
    /// 进度回调：阶段切换 + 流式 token + 逐词进度 → 切回主线程更新 UI。
    private var progressHandler: @Sendable (GenProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.applyProgress(progress)
            }
        }
    }

    /// 应用一次进度事件（主线程；progressHandler 与测试共用）。
    func applyProgress(_ progress: GenProgress) {
        switch progress {
        case .stage(let stage):
            genStage = stage
            if let id = activityID {
                let p: Double
                let msg: String
                switch stage {
                case .strategy: p = 0.05; msg = "正在制定生成策略…"
                case .planning: p = 0.15; msg = "正在联想打草稿…"
                case .generating: p = 0.4; msg = "正在生成正文…"
                case .embedding: p = 0.55; msg = "正在逐词融入…"
                case .polishing: p = 0.8; msg = "正在改写润色…"
                case .saving: p = 0.95; msg = "正在保存…"
                }
                GlobalActivityCenter.shared.update(id, progress: p, message: msg)
            }
        case .token(let text):
            streamedText += text
        case .word(let done, let total, let word):
            embedWordProgress = EmbedWordProgress(done: done, total: total, word: word)
        }
    }
```

- `runGenerate()` 开头重置处加：

```swift
        embedWordProgress = nil
        lastSkipped = []
```

- 完成回调（`self.lastStrategy = article.strategy` 旁）加：

```swift
                        self.lastSkipped = article.skippedWords
```

- 加查询方法（类末尾）：

```swift
    /// 覆盖 ✗ chip 的悬停原因（来自跳过词结构化报告）。
    func skippedReason(for word: String) -> String? {
        lastSkipped.first { $0.word == word }?.reason
    }
```

`GenerateView.swift`：

- `progressSection` 内（`Text(vm.genStage?.label ...)` 之后）追加：

```swift
            if let p = vm.embedWordProgress {
                Text("正在融入 \(p.done + 1)/\(p.total)：\(p.word)")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- `resultSummary` 的覆盖 chips `ForEach(vm.coverage)` 内加悬停原因：把 `Text(c.word).font(.caption)` 那行替换为：

```swift
                            Text(c.word).font(.caption)
                                .help(vm.skippedReason(for: c.word) ?? "未嵌入正文")
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -5` → PASS。
Run: `swift build 2>&1 | tail -5` → Build complete，0 warning。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift Sources/WordRecitingApp/UI/Creation/GenerateView.swift Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift
git commit -m "feat(ui): show per-word embed progress and skipped-word reasons"
```

---

### Task 8: 全量回归

**Files:**
- 无代码改动（仅验证）

- [ ] **Step 1: 全量构建**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete，0 warning。

- [ ] **Step 2: 全量测试（跳过真实模型测试类）**

Run: `swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests 2>&1 | tail -8`
Expected: 全绿 0 failures；测试数 ≈ 356 = 325（原有）− 7（三个跳过类）+ 7（SentenceSplitter）+ 14（AgenticPrompts）+ 14（AgenticEmbedding）+ 1（AppSettings）+ 2（GenerateViewModel）。

- [ ] **Step 3: 收尾检查**

- `AgenticEmbeddingTests`、`SentenceSplitterTests`、`AgenticPromptsTests` 三个文件各 ≤ 300 行？若超限拆。
- `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift` 与 `+AgenticLoop.swift` 各 ≤ 300 行？
- 备忘录更新：在「关键约定」区追加本方案交付要点（管线、验证强度、跳过词结构化报告、测试数）。

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: agentic word embedding delivered (full suite green)"
```

---

## 自检记录（实现时复查）

- **Spec 覆盖**：纯净草稿(plainPrompt)→切句(SentenceSplitter)→联想锚点(resolveAnchors，含 token 预算降级)→逐词循环(embedWord)→评估(evaluateRewritten)→换锚点/跳过(降级链)→回填+润色(smoothAt)→规则兜底(makeArticle)→span(findTargetSpans) ✓；验证强度(AppSettings)✓；结构化报告(skippedWords→lastSkipped→tooltip)✓；进度(.embedding + .word)✓；**本地模型上下文窗口约束**：锚点选句 token 预算 + 长文本地匹配降级（Task 5）、逐词/润色/联想 prompt 均短 ✓。
- **类型一致性**：`EmbedConfig(verification:maxAttempts:maxAnchorSwitches:)` 成员顺序在 Task 4 测试与实现一致（`config: .init(verification: .light, maxAttempts: 3, maxAnchorSwitches: 0)`）。`EmbedWordProgress` 在 Task 7 测试与实现字段一致。`resolveAnchors`/`estimateTokens`/`anchorTokenBudget` 在 Task 5 测试与实现签名一致（internal，非 private）。
- **风险**：`SequenceMockClient`/`SeqClient` 响应耗尽后重复返回最后一个——测试中响应用满/留够；若管线调用数变化导致断言失败，先核对调用序列注释。`resolveAnchors` 的 token 降级路径只在草稿超 900 token 时触发——端到端测试草稿都是短文，走 LLM 选句路径，调用数不变。
