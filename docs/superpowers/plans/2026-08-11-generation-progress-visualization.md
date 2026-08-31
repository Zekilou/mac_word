# 生成过程可视化（思考日志 + Token 指标 + 输出标记）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 生成过程中在左侧面板实时展示动态思考日志、首 token/token 速率/总耗时指标，并用 `===ARTICLE_START===/===ARTICLE_END===` 约定标记 + 流式剥离保证正文不混入思考/提示词。

**Architecture:** 新增 `GenProgress.thought(GenThought)` 事件由生成器各步发出，VM 按 id upsert 成日志、计时算指标；新增 `MarkedStreamBuffer` 在生成器流式回调里剥离标记与前置思考；左侧面板新增「生成过程」区渲染日志 + 指标 + 停止按钮。

**Tech Stack:** Swift / SwiftUI / llama.cpp (LlamaSwift) / 无第三方新增依赖。

**规范（项目铁律）：**
- TDD：先写失败测试 → 实现 → 全绿。源文件 ≤ 300 行（GenerateView/GenerateViewModel 为历史超限文件，只做增量修改不拆）。
- 测试只用 mock，**禁止真实模型推理测试**。运行测试跳过：`swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests`。
- 全量跑测试用过滤参数，build 0 warning。

---

## 文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `ContentGeneration/LocalLLMGenerator.swift` | 修改 | `GenProgress.thought` + `GenThought`；`generatePrompt/polishPrompt/rewritePrompt` 加标记指令；generate() 接入标记流式 + 思考事件 + 取消检查 |
| `ContentGeneration/GenStrategy.swift` | 修改 | `plainPrompt` 加标记指令 |
| `ContentGeneration/MarkedStreamBuffer.swift` | 新建 | 流式标记剥离（独立可测） |
| `ContentGeneration/AgenticPrompts.swift` | 修改 | `articleStart/articleEnd/extractMarkedBody` |
| `ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift` | 修改 | draft 标记流式 + 思考事件（draft/anchor/smooth/skipped）+ 取消检查 |
| `ContentGeneration/LocalLLMGenerator+AgenticLoop.swift` | 修改 | embedWord 逐词思考事件（running→done/failed，detail=尝试记录）+ 取消检查 |
| `UI/Creation/GenerateViewModel.swift` | 修改 | `thinkingLog` + `streamStats` + thought 路由 + 停止 + save 事件 |
| `UI/Creation/GenThinkingLogView.swift` | 新建 | 思考日志视图 + 指标行 |
| `UI/Creation/GenerateView.swift` | 修改 | 左侧「生成过程」区（日志 + 指标 + 停止按钮） |
| `Tests/.../ContentGeneration/MarkedStreamBufferTests.swift` | 新建 | 标记剥离测试 |
| `Tests/.../ContentGeneration/AgenticPromptsTests.swift` | 修改 | extractMarkedBody + prompt 标记断言 |
| `Tests/.../ContentGeneration/AgenticEmbeddingTests.swift` | 修改 | thought 事件序列断言 |
| `Tests/.../UI/GenerateViewModelTests.swift` | 修改 | thinkingLog/streamStats/停止 |

测试根：`Tests/WordRecitingAppTests`。全部路径前缀 `Sources/WordRecitingApp/`。

---

### Task 1: GenThought 类型 + GenProgress.thought

**Files:**
- Modify: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift`（`GenProgress` 加 case + `GenThought` 定义）
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift`（progressHandler switch 补 .thought 穷尽，先占位）
- Test: `Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift`

- [ ] **Step 1: 写失败测试**

`AgenticEmbeddingTests.swift` 追加：

```swift
    // MARK: - 思考事件类型

    func testGenThoughtFields() {
        let t = GenThought(
            id: "strategy", kind: .strategy,
            message: "策略：先写后改写", detail: nil, status: .done)
        XCTAssertEqual(t.kind, .strategy)
        XCTAssertEqual(t.status, .done)
        XCTAssertEqual(GenThought.Kind.allCases.count, 7)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -4`
Expected: FAIL（GenThought 不存在）。

- [ ] **Step 3: 实现**

`LocalLLMGenerator.swift` 在 `GenProgress` 处改为：

```swift
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
```

`GenerateViewModel.swift` 的 `applyProgress` switch 加 case（先占位，Task 4 正式实现）：

```swift
        case .thought(let thought):
            // TODO(Task 4): upsert 到 thinkingLog
            _ = thought
```

（若 switch 已有其他 case，保持穷尽。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -4` → PASS；`swift build 2>&1 | tail -3` → 0 warning。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift
git commit -m "feat(gen): add GenThought thinking event type"
```

---

### Task 2: MarkedStreamBuffer + extractMarkedBody + 标记指令

**Files:**
- Create: `Sources/WordRecitingApp/ContentGeneration/MarkedStreamBuffer.swift`
- Create: `Tests/WordRecitingAppTests/ContentGeneration/MarkedStreamBufferTests.swift`
- Modify: `Sources/WordRecitingApp/ContentGeneration/AgenticPrompts.swift`（articleStart/articleEnd/extractMarkedBody）
- Modify: `Sources/WordRecitingApp/ContentGeneration/GenStrategy.swift`（plainPrompt 加标记指令）
- Modify: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift`（generatePrompt/polishPrompt/rewritePrompt 加标记指令）
- Modify: `Tests/WordRecitingAppTests/ContentGeneration/AgenticPromptsTests.swift`

- [ ] **Step 1: 写失败测试**

`MarkedStreamBufferTests.swift` 新建：

```swift
import XCTest
@testable import WordRecitingApp

/// 输出约定标记的流式剥离：跨块识别、思考前置跳过、结束标记剥离、无标记回退全量。
final class MarkedStreamBufferTests: XCTestCase {

    func testStripsOpeningAndClosing() {
        var b = MarkedStreamBuffer()
        let c1 = b.append("===ARTICLE_START===The world is changing.")
        XCTAssertEqual(c1, "The world is changing.")
        XCTAssertEqual(b.append(" It keeps moving."), " It keeps moving.")
        let c2 = b.append("===ARTICLE_END===")
        XCTAssertEqual(c2, "")
        XCTAssertEqual(b.finalize(), "The world is changing. It keeps moving.")
    }

    func testOpeningSplitAcrossChunks() {
        var b = MarkedStreamBuffer()
        XCTAssertEqual(b.append("===ARTICLE_"), "")
        XCTAssertEqual(b.append("START===\nHello there."), "\nHello there.")
        XCTAssertEqual(b.finalize(), "\nHello there.")
    }

    func testSkipsThinkingBeforeOpening() {
        var b = MarkedStreamBuffer()
        let c1 = b.append("Sure! Here is the article.\n===ARTICLE_START===Hello.")
        XCTAssertEqual(c1, "Hello.")
        XCTAssertEqual(b.finalize(), "Hello.")
    }

    func testNoOpeningMarkerFallsBackToWhole() {
        var b = MarkedStreamBuffer()
        let c1 = b.append("Just a plain answer with no markers at all.")
        XCTAssertEqual(c1, "Just a plain answer with no markers at all.")
        XCTAssertEqual(b.finalize(), "Just a plain answer with no markers at all.")
    }

    func testClosingSplitAcrossChunks() {
        var b = MarkedStreamBuffer()
        _ = b.append("===ARTICLE_START===Body text")
        XCTAssertEqual(b.append("===ARTICLE_"), "")
        XCTAssertEqual(b.append("END===tail junk"), "")
        XCTAssertEqual(b.finalize(), "Body text")
    }

    func testPartialClosingAtStreamEndIsDropped() {
        var b = MarkedStreamBuffer()
        _ = b.append("===ARTICLE_START===Body text")
        XCTAssertEqual(b.append("===ARTICLE_END"), "")
        XCTAssertEqual(b.finalize(), "Body text", "结尾半截结束标记应被丢弃")
    }

    func testRawAllKeepsOriginal() {
        var b = MarkedStreamBuffer()
        _ = b.append("===ARTICLE_START===Hi.")
        _ = b.append(" Bye.===ARTICLE_END===")
        XCTAssertEqual(b.rawAll, "===ARTICLE_START===Hi. Bye.===ARTICLE_END===")
        XCTAssertEqual(b.body, "Hi. Bye.")
    }
}
```

`AgenticPromptsTests.swift` 追加：

```swift
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

    func testPlainPromptContainsMarkerInstruction() {
        let p = GenStrategyPrompt.plainPrompt(theme: "科技", maxWords: 100)
        XCTAssertTrue(p.contains("===ARTICLE_START==="), "纯净草稿应要求标记")
        XCTAssertTrue(p.contains("===ARTICLE_END==="))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MarkedStreamBufferTests --filter AgenticPromptsTests 2>&1 | tail -4`
Expected: FAIL（类型不存在 / 断言失败）。

- [ ] **Step 3: 实现**

创建 `Sources/WordRecitingApp/ContentGeneration/MarkedStreamBuffer.swift`：

```swift
import Foundation

/// 流式剥离输出约定标记：跳过开标记前的思考/前言；延迟尾部技术识别跨 chunk 的结束标记。
/// @ai: 生成器在 client.stream 的 onToken 里清洗后再转发 onProgress；VM 只收干净正文。
struct MarkedStreamBuffer {
    static let opening = "===ARTICLE_START==="
    static let closing = "===ARTICLE_END==="

    /// 完整原始流（最终提取与测试用）。
    private(set) var rawAll = ""
    /// 累积的干净正文（不含标记与前置思考）。
    private(set) var body = ""
    private var pending = ""
    private var started = false
    private var finished = false

    /// 追加一块流，返回可提交（展示）的干净文本。
    mutating func append(_ chunk: String) -> String {
        guard !finished else { return "" }
        rawAll += chunk
        pending += chunk
        if !started {
            if let r = pending.range(of: Self.opening) {
                started = true
                pending = String(pending[r.upperBound...])
            } else if !Self.opening.hasPrefix(pending) {
                started = true   // 模型未写开标记 → 全量展示（与 extractMarkedBody 回退一致）
            } else {
                return ""   // pending 仍是开标记前缀，继续等
            }
        }
        // 结束标记完整出现 → 截断提交并结束（后续丢弃）
        if let r = pending.range(of: Self.closing) {
            finished = true
            let before = String(pending[..<r.lowerBound])
            pending = ""
            if !before.isEmpty { body += before }
            return before
        }
        // 延迟尾部：与 closing 前缀匹配的最长后缀扣留，其余提交
        let hold = holdLength(pending)
        let commitCount = pending.count - hold
        guard commitCount > 0 else { return "" }
        let committed = String(pending.prefix(commitCount))
        body += committed
        pending = String(pending.dropFirst(commitCount))
        return committed
    }

    /// 流结束：剥离残留结束标记（含被截断的前缀），返回完整干净正文。
    mutating func finalize() -> String {
        if !finished {
            if pending.hasPrefix(Self.closing) || Self.closing.hasPrefix(pending) {
                pending = ""
            }
            body += pending
            pending = ""
        }
        return body
    }

    /// pending 中与 closing 前缀匹配的最长后缀长度（0..closing.count）。
    private func holdLength(_ s: String) -> Int {
        let n = min(s.count, Self.closing.count)
        guard n > 0 else { return 0 }
        var best = 0
        let chars = Array(s)
        for k in 1...n {
            if Self.closing.hasPrefix(String(chars.suffix(k))) { best = k }
        }
        return best
    }
}
```

`AgenticPrompts.swift` 加（文件末尾 `parseAssociations` 后）：

```swift
    // MARK: - 输出约定标记

    static let articleStart = "===ARTICLE_START==="
    static let articleEnd = "===ARTICLE_END==="

    /// 提取两个标记之间的正文；标记缺失/半截回退 cleanArticle 全量。
    static func extractMarkedBody(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = s.range(of: articleStart),
              let endRange = s.range(of: articleEnd) else {
            return LocalLLMGenerator.cleanArticle(s)
        }
        let inner = String(s[start.upperBound..<endRange.lowerBound])
        let cleaned = LocalLLMGenerator.cleanArticle(inner)
        return cleaned.isEmpty ? LocalLLMGenerator.cleanArticle(s) : cleaned
    }
```

`GenStrategy.swift` 的 `plainPrompt` 末尾（"Output ONLY the article body." 后）追加：

```swift
        - Wrap the article exactly with:
          ===ARTICLE_START===
          (article body)
          ===ARTICLE_END===
        - Output nothing outside these markers.
```

`LocalLLMGenerator.swift` 三个 prompt 的 `Output ONLY` 相关行后各追加相同标记段（`generatePrompt` / `polishPrompt` / `rewritePrompt`），措辞一致：

```swift
        - Wrap the output exactly with:
          ===ARTICLE_START===
          (content)
          ===ARTICLE_END===
        - Output nothing outside these markers.
```

（generatePrompt 的 `Output ONLY the article body.` 行后；polishPrompt 的 `Output ONLY the cleaned article text.` 后；rewritePrompt 的 `Output ONLY the rewritten article body.` 后。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter MarkedStreamBufferTests 2>&1 | tail -4` → 7 PASS。
Run: `swift test --filter AgenticPromptsTests 2>&1 | tail -4` → 15 PASS（原 12 + 新 3）。
Run: `swift build 2>&1 | tail -3` → 0 warning。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ContentGeneration/MarkedStreamBuffer.swift Sources/WordRecitingApp/ContentGeneration/AgenticPrompts.swift Sources/WordRecitingApp/ContentGeneration/GenStrategy.swift Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift Tests/WordRecitingAppTests/ContentGeneration/MarkedStreamBufferTests.swift Tests/WordRecitingAppTests/ContentGeneration/AgenticPromptsTests.swift
git commit -m "feat(gen): add output markers with streaming strip and extraction"
```

---

### Task 3: 生成器接入（标记流式 + 思考事件 + 取消检查）

**Files:**
- Modify: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift`（generate() 正文/自查流式 + 思考事件 + checkCancellation）
- Modify: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift`（draft/anchor/smooth/skipped 思考事件 + 标记流式 + checkCancellation）
- Modify: `Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticLoop.swift`（embedWord 逐词思考事件 + checkCancellation）
- Test: `Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift`

- [ ] **Step 1: 写失败测试**

`AgenticEmbeddingTests.swift` 追加（思考事件收集辅助 + 断言）：

```swift
    // MARK: - 思考事件（thought 路由）

    private final class ThoughtBox: @unchecked Sendable {
        var items: [GenThought] = []
    }

    /// plan-embed 路径应发出：strategy → planning → draft → polish 的思考事件。
    func testGenerateEmitsThoughtEventsPlanEmbed() async throws {
        let appDB = try AppDatabase.inMemory()
        let world = World(database: appDB)
        let graph = world.graph
        let now = Date()
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
            ],
            textComponents: [TextComponent(entityId: "lemma-1", textA: "abandon", textB: nil, language: "en")],
            deckMetas: [DeckMetaComponent(entityId: "deck-1", name: "T", sourceKind: "csv", sourcePath: nil, importedAt: now)],
            edges: [], failures: [])
        try world.run(ImportSystem(), context: batch)

        let box = ThoughtBox()
        let client = SeqClient(responses: [
            "STRATEGY: plan-embed\nWINDOW: whole\nFALLBACK: skip",
            "- abandon: intro\n- Intro",
            "===ARTICLE_START===We should not abandon our dreams.===ARTICLE_END===",
            "===ARTICLE_START===Technology changes our lives.===ARTICLE_END===",
        ])
        let gen = LocalLLMGenerator(client: client, onProgress: { progress in
            if case .thought(let t) = progress { box.items.append(t) }
        })
        _ = try await gen.generate(
            mode: .generate, sourceText: "科技", targetLemmas: ["lemma-1"],
            constraints: GenerationConstraints(), graph: graph)

        let ids = box.items.map(\.id)
        XCTAssertTrue(ids.contains("strategy"))
        XCTAssertTrue(ids.contains("planning"))
        XCTAssertTrue(box.items.first { $0.id == "strategy" }?.status == .done)
        XCTAssertTrue(box.items.first { $0.id == "planning" }?.status == .done)
        XCTAssertTrue(box.items.contains { $0.id == "draft" && $0.status == .done },
                      "正文流式应有 draft 完成事件，实际 \(ids)")
    }

    /// generate-rewrite 路径应发出：strategy → draft → anchor → embed-<word> → smooth。
    func testGenerateViaRewriteEmitsThoughtEvents() async throws {
        let appDB = try AppDatabase.inMemory()
        let world = World(database: appDB)
        let graph = world.graph
        let now = Date()
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
                .init(id: "lemma-2", kind: .lemma, createdAt: now),
            ],
            textComponents: [
                TextComponent(entityId: "lemma-1", textA: "abandon", textB: nil, language: "en"),
                TextComponent(entityId: "lemma-2", textA: "battle", textB: nil, language: "en"),
            ],
            deckMetas: [DeckMetaComponent(entityId: "deck-1", name: "T", sourceKind: "csv", sourcePath: nil, importedAt: now)],
            edges: [], failures: [])
        try world.run(ImportSystem(), context: batch)

        let box = ThoughtBox()
        let client = SeqClient(responses: [
            "STRATEGY: generate-rewrite\nWINDOW: sentence\nFALLBACK: skip",
            "===ARTICLE_START===A normal article about daily life. People wake up, work, and rest each day.===ARTICLE_END===",
            "{\"abandon\": {\"index\": 0, \"associations\": \"give up\"}, \"battle\": {\"index\": 1, \"associations\": \"fight\"}}",
            "We should never abandon our dreams.",
            "Yes.",
            "The battle continues every day.",
            "Yes.",
            "We should never abandon our dreams.\nThe battle continues every day.",
            "We should never abandon our dreams.\nThe battle continues every day.",
        ])
        let gen = LocalLLMGenerator(client: client, onProgress: { progress in
            if case .thought(let t) = progress { box.items.append(t) }
        })
        let article = try await gen.generate(
            mode: .generate, sourceText: "科技", targetLemmas: ["lemma-1", "lemma-2"],
            constraints: GenerationConstraints(), graph: graph)

        let ids = box.items.map(\.id)
        XCTAssertTrue(ids.contains("anchor"), "应有锚点事件，实际 \(ids)")
        XCTAssertTrue(ids.contains("embed-lemma-1"), "应有逐词事件，实际 \(ids)")
        XCTAssertTrue(ids.contains("embed-lemma-2"))
        XCTAssertTrue(box.items.contains { $0.id == "embed-lemma-1" && $0.status == .done })
        XCTAssertTrue(article.body.lowercased().contains("abandon"))
        XCTAssertTrue(article.body.lowercased().contains("battle"))
    }
```

注意：现有 `LocalLLMGenerator` 的 init 是否带 `onProgress` 参数？是（`init(client:maxTokens:temperature:onProgress:)`）。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -4`
Expected: FAIL（生成器未发 thought 事件 / 标记剥离未生效导致正文断言失败）。

- [ ] **Step 3: 实现**

`LocalLLMGenerator.swift` 的 `generate()` 改造（替换 strategy/planning/正文/自查相关块）：

```swift
        var plan: String?
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
        var buffer = MarkedStreamBuffer()
        _ = try await client.stream(
            prompt: prompt, maxTokens: maxTokens, temperature: temperature
        ) { [onProgress] token in
            let clean = buffer.append(token)
            if !clean.isEmpty { onProgress?(.token(clean)) }
        }
        var body = Self.cleanArticle(buffer.finalize())
        onProgress?(.thought(GenThought(
            id: "draft", kind: .generating,
            message: "生成正文完成（\(buffer.rawAll.count) 字符）", detail: nil, status: .done)))
        if !body.isEmpty {
            onProgress?(.stage(.polishing))
            onProgress?(.thought(GenThought(
                id: "polish", kind: .polishing,
                message: "正在改写润色…", detail: nil, status: .running)))
            try Task.checkCancellation()
            var polishBuffer = MarkedStreamBuffer()
            let polished = try? await client.stream(
                prompt: Self.polishPrompt(article: body),
                maxTokens: maxTokens, temperature: 0.3,
                onToken: { [onProgress] token in
                    let clean = polishBuffer.append(token)
                    if !clean.isEmpty { onProgress?(.token(clean)) }
                })
            if let polished, !polished.isEmpty {
                let cleaned = Self.cleanArticle(polishBuffer.finalize())
                if !cleaned.isEmpty { body = cleaned }
            }
            onProgress?(.thought(GenThought(
                id: "polish", kind: .polishing,
                message: "润色完成", detail: nil, status: .done)))
        }
```

注意：`buffer.rawAll.count` 是字符数近似展示，可接受。原代码中 `raw`/`polished` 的后续 `body` 逻辑不变（fallback 规则替换部分不动）。

`LocalLLMGenerator+AgenticLoop.swift` 的 `embedWord` 内（`while true` 开头）与每次尝试前加取消检查，并发出逐词思考事件：

```swift
        onProgress?(.thought(GenThought(
            id: "embed-\(word)", kind: .embedding,
            message: "融入 \(word)（锚点句#\(anchor)）", detail: nil, status: .running)))
        let history = AttemptHistory()
        var anchor = anchorIndex
        var anchorSwitches = 0
        while true {
            try Task.checkCancellation()
            guard sentences.indices.contains(anchor) else {
                onProgress?(.thought(GenThought(
                    id: "embed-\(word)", kind: .embedding,
                    message: "融入 \(word)：锚点句缺失，跳过", detail: nil, status: .failed)))
                return .skipped(SkippedWord(word: word, reason: "草稿为空或锚点句缺失"))
            }
            let sentence = sentences[anchor]
            var attempts = 0
            var lastFeedback: [String]?
            while attempts < config.maxAttempts {
                try Task.checkCancellation()
                ...原改写逻辑不变...
                switch await evaluateRewritten(...) {
                case .pass:
                    onProgress?(.thought(GenThought(
                        id: "embed-\(word)", kind: .embedding,
                        message: "融入 \(word)：改写成功（锚点句#\(anchor)）",
                        detail: nil, status: .done)))
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
            let reason = "\(config.maxAttempts) 次尝试后仍无法自然融入"
            onProgress?(.thought(GenThought(
                id: "embed-\(word)", kind: .embedding,
                message: "融入 \(word)：失败，跳过", detail: reason, status: .failed)))
            return .skipped(SkippedWord(word: word, reason: reason))
        }
```

注意：`embedWord` 现为 `async throws`（加 checkCancellation），调用方 `generateViaRewrite` 的调用处相应处理（它本身是 async throws，`try await` 即可）。

`LocalLLMGenerator+AgenticEmbedding.swift` 的 `generateViaRewrite`：

- draft 流式改标记（`onProgress?.token` 只推干净文本），并发出 draft/anchor/smooth/skipped 思考事件；各步前加 `try Task.checkCancellation()`。

替换 draft 块：

```swift
        onProgress?(.stage(.generating))
        onProgress?(.thought(GenThought(
            id: "draft", kind: .generating,
            message: "正在生成正文…", detail: nil, status: .running)))
        try Task.checkCancellation()
        var draftBuffer = MarkedStreamBuffer()
        _ = try await client.stream(
            prompt: GenStrategyPrompt.plainPrompt(theme: theme, maxWords: maxWords),
            maxTokens: maxTokens, temperature: temperature
        ) { [onProgress] token in
            let clean = draftBuffer.append(token)
            if !clean.isEmpty { onProgress?(.token(clean)) }
        }
        var body = Self.cleanArticle(draftBuffer.finalize())
        onProgress?(.thought(GenThought(
            id: "draft", kind: .generating,
            message: "草稿完成（\(draftBuffer.rawAll.count) 字符）", detail: nil, status: .done)))
```

`resolveAnchors` 调用处前加：

```swift
                onProgress?(.thought(GenThought(
                    id: "anchor", kind: .planning,
                    message: "正在联想并匹配锚点句…", detail: nil, status: .running)))
                let anchors = await resolveAnchors(words: words, sentences: sentences)
                onProgress?(.thought(GenThought(
                    id: "anchor", kind: .planning,
                    message: "锚点匹配完成（\(anchors.count) 词）", detail: nil, status: .done)))
```

`embedWord` 调用处改 `try await`。`smoothAt` 调用前加思考事件与取消检查：

```swift
                onProgress?(.thought(GenThought(
                    id: "smooth", kind: .polishing,
                    message: "正在衔接润色…", detail: nil, status: .running)))
                try Task.checkCancellation()
                finalSentences = await smoothAt(finalSentences, replaced: Set(replacements.keys))
                onProgress?(.thought(GenThought(
                    id: "smooth", kind: .polishing,
                    message: "衔接润色完成（\(replacements.count) 处）", detail: nil, status: .done)))
```

`makeArticle` 里跳过词报告前加思考事件与取消检查（`makeArticle` 已是 async throws）：

```swift
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
```

**同步既有测试**：`embedWord` 变为 `async throws` 后，`AgenticEmbeddingTests.swift` 中既有的 8 个 `await gen.embedWord(...)` 调用需全部改为 `try await gen.embedWord(...)`（编译要求，逐个替换；测试断言不变）。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AgenticEmbeddingTests 2>&1 | tail -4` → 全过（含 2 个新 thought 测试）。
Run: `swift test --filter LocalLLMGeneratorTests 2>&1 | tail -4` → 全过（plan-embed 既有测试不受影响）。
Run: `swift build 2>&1 | tail -3` → 0 warning。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator.swift Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift Sources/WordRecitingApp/ContentGeneration/LocalLLMGenerator+AgenticLoop.swift Tests/WordRecitingAppTests/ContentGeneration/AgenticEmbeddingTests.swift
git commit -m "feat(gen): emit thinking events and strip markers in generator streams"
```

---

### Task 4: VM（thinkingLog + streamStats + thought 路由 + 停止）

**Files:**
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift`
- Modify: `Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift`

- [ ] **Step 1: 写失败测试**

`GenerateViewModelTests.swift` 追加：

```swift
    // MARK: - 思考日志 + Token 指标

    @MainActor func testThoughtEventsUpsertLog() {
        let vm = makeVM()
        vm.applyProgress(.thought(GenThought(
            id: "strategy", kind: .strategy, message: "正在制定生成策略…", detail: nil, status: .running)))
        XCTAssertEqual(vm.thinkingLog.count, 1)
        vm.applyProgress(.thought(GenThought(
            id: "strategy", kind: .strategy, message: "策略：先写后改写", detail: nil, status: .done)))
        XCTAssertEqual(vm.thinkingLog.count, 1, "同 id 应 upsert")
        XCTAssertEqual(vm.thinkingLog[0].message, "策略：先写后改写")
        XCTAssertEqual(vm.thinkingLog[0].status, .done)
    }

    @MainActor func testStreamStatsTracksTokensAndRate() async throws {
        let vm = makeVM()
        vm.applyProgress(.stage(.generating))
        vm.applyProgress(.token("Hello"))
        let s1 = vm.streamStats
        XCTAssertEqual(s1.tokens, 1)
        XCTAssertNotNil(s1.firstTokenLatency)
        XCTAssertGreaterThanOrEqual(s1.rate, 0)
        try await Task.sleep(nanoseconds: 10_000_000)   // 保证 elapsed > 0，速率断言不 flaky
        vm.applyProgress(.token(" world"))
        XCTAssertEqual(vm.streamStats.tokens, 2)
        XCTAssertGreaterThan(vm.streamStats.rate, 0, "速率应随 token 增长")
    }

    @MainActor func testStopCancelsGeneration() async throws {
        let vm = makeVM()
        // 无活动任务时 stop 不崩
        vm.stopGenerating()
        XCTAssertFalse(vm.isGenerating)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -4`
Expected: FAIL（thinkingLog/streamStats/stopGenerating 不存在）。

- [ ] **Step 3: 实现**

`GenerateViewModel.swift`：

- 加类型（类外，`EmbedWordProgress` 附近）：

```swift
/// 思考日志条目（VM 侧，按生成器 thought 事件 upsert）。
struct ThinkingLogItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: GenThought.Kind
    var message: String
    var detail: String?
    var status: GenThought.Status
    let elapsedAt: TimeInterval
}

/// 流式阶段实时指标。
struct StreamStats: Equatable, Sendable {
    var firstTokenLatency: TimeInterval?
    var tokens: Int = 0
    var rate: Double = 0
}
```

- 输出区加属性（`lastSkipped` 旁）：

```swift
    /// 思考日志（生成过程中实时累积，路由到左侧进度区）。
    var thinkingLog: [ThinkingLogItem] = []
    /// 当前流式阶段指标（首 token/速率/token 数）。
    var streamStats = StreamStats()
```

- 生成计时属性（类内私有）：

```swift
    /// 本次生成开始时间（日志条目耗时基准）。
    private var genStartedAt: Date?
    /// 当前流式阶段开始时间。
    private var phaseStartAt: Date?
    /// 是否已收到首个正文 token。
    private var firstTokenSeen = false
```

- `applyProgress` 改造：

```swift
    func applyProgress(_ progress: GenProgress) {
        switch progress {
        case .stage(let stage):
            genStage = stage
            if stage == .generating || stage == .polishing {
                phaseStartAt = Date()
                firstTokenSeen = false
                streamStats = StreamStats()
            }
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
            let now = Date()
            if phaseStartAt == nil { phaseStartAt = now }
            if !firstTokenSeen {
                firstTokenSeen = true
                streamStats.firstTokenLatency = now.timeIntervalSince(phaseStartAt!)
            }
            streamStats.tokens += 1
            let elapsed = now.timeIntervalSince(phaseStartAt!)
            if elapsed > 0 { streamStats.rate = Double(streamStats.tokens) / elapsed }
        case .word(let done, let total, let word):
            embedWordProgress = EmbedWordProgress(done: done, total: total, word: word)
        case .thought(let thought):
            let elapsed = Date().timeIntervalSince(genStartedAt ?? Date())
            if let idx = thinkingLog.firstIndex(where: { $0.id == thought.id }) {
                thinkingLog[idx] = ThinkingLogItem(
                    id: thought.id, kind: thought.kind, message: thought.message,
                    detail: thought.detail, status: thought.status,
                    elapsedAt: thinkingLog[idx].elapsedAt)
            } else {
                thinkingLog.append(ThinkingLogItem(
                    id: thought.id, kind: thought.kind, message: thought.message,
                    detail: thought.detail, status: thought.status, elapsedAt: elapsed))
            }
        }
    }
```

- `runGenerate()` 开头（重置区）加：

```swift
        thinkingLog = []
        streamStats = StreamStats()
        genStartedAt = Date()
        phaseStartAt = nil
        firstTokenSeen = false
```

- 落库前发 save 思考事件（`try world.run(ContentGenSystem(), ...)` 前）：

```swift
                    applyProgress(.thought(GenThought(
                        id: "save", kind: .saving,
                        message: "正在保存…", detail: nil, status: .running)))
```

落库成功后（完成回调里）：

```swift
                        applyProgress(.thought(GenThought(
                            id: "save", kind: .saving,
                            message: "保存完成", detail: nil, status: .done)))
```

- 停止方法（类末尾）：

```swift
    /// 停止当前生成（取消全局活动中心任务；步间生效）。
    func stopGenerating() {
        guard let id = activityID, isGenerating else { return }
        GlobalActivityCenter.shared.cancel(id)
    }
```

- `runGenerate` 的 catch 分支加 CancellationError 处理（两个 catch 都加）：

```swift
                } catch is CancellationError {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.isGenerating = false
                        self.applyProgress(.thought(GenThought(
                            id: "info", kind: .info,
                            message: "已取消", detail: nil, status: .done)))
                    }
                } catch {
                    ...
                }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -4` → 全过。
Run: `swift build 2>&1 | tail -3` → 0 warning。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift
git commit -m "feat(vm): route thinking log and compute stream stats with stop support"
```

---

### Task 5: 左侧面板视图（GenThinkingLogView + GenerateView 接入）

**Files:**
- Create: `Sources/WordRecitingApp/UI/Creation/GenThinkingLogView.swift`
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateView.swift`

- [ ] **Step 1: 实现（视图无单元测试，build 验证）**

创建 `Sources/WordRecitingApp/UI/Creation/GenThinkingLogView.swift`：

```swift
import SwiftUI

/// 生成过程可视化：思考日志 + 实时指标（路由到左侧生成面板的进度展示区）。
struct GenThinkingLogView: View {
    let log: [ThinkingLogItem]
    let stats: StreamStats
    let isGenerating: Bool
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("⏱ 生成过程").font(.caption.weight(.semibold))
                Spacer()
                if isGenerating {
                    Button(role: .destructive) { onStop() } label: {
                        Label("停止", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if log.isEmpty {
                Text("正在启动…")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(log) { item in
                                logRow(item)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 260)
                    .onChange(of: log.count) { _, _ in
                        withAnimation { proxy.scrollTo(log.last?.id, anchor: .bottom) }
                    }
                }
            }
            metricsRow
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func logRow(_ item: ThinkingLogItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(icon(item.kind)).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(statusSymbol(item.status)).font(.caption2)
                    Text(item.message)
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? Color.red : Color.primary)
                }
                if let detail = item.detail, !detail.isEmpty {
                    DisclosureGroup("详情") {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption2)
                }
            }
            Spacer(minLength: 4)
            Text(String(format: "%.1fs", item.elapsedAt))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// 实时指标行：首 token / 速率 / token 数。
    private var metricsRow: some View {
        HStack(spacing: 10) {
            metric("首token",
                   stats.firstTokenLatency.map { String(format: "%.1fs", $0) } ?? "—")
            metric("速率", stats.tokens > 0 ? String(format: "%.1f tok/s", stats.rate) : "—")
            metric("tokens", "\(stats.tokens)")
            Spacer()
        }
        .font(.caption2)
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func icon(_ kind: GenThought.Kind) -> String {
        switch kind {
        case .strategy: return "🧭"
        case .planning: return "✏️"
        case .generating: return "📝"
        case .embedding: return "🎯"
        case .polishing: return "✨"
        case .saving: return "💾"
        case .info: return "ℹ️"
        }
    }

    private func statusSymbol(_ status: GenThought.Status) -> String {
        switch status {
        case .running: return "⟳"
        case .done: return "✓"
        case .failed: return "✗"
        }
    }
}
```

`GenerateView.swift`：
- 在按钮 HStack 后（`if vm.isGenerating { progressSection }` 替换）加生成过程区：

```swift
                HStack(spacing: 8) {
                    Button {
                        vm.runGenerate()
                    } label: {
                        Label("生成文章", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isGenerating)
                    Spacer()
                }

                if vm.isGenerating {
                    GenThinkingLogView(
                        log: vm.thinkingLog,
                        stats: vm.streamStats,
                        isGenerating: vm.isGenerating,
                        onStop: { vm.stopGenerating() })
                }
```

删除原 `progressSection` 计算属性（或保留不用；为整洁删除）。`progressSection` 若被删除，检查无其他引用（只有按钮区用过）。

- [ ] **Step 2: build 验证**

Run: `swift build 2>&1 | tail -3` → 0 warning。
Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -4` → 全过。

- [ ] **Step 3: Commit**

```bash
git add Sources/WordRecitingApp/UI/Creation/GenThinkingLogView.swift Sources/WordRecitingApp/UI/Creation/GenerateView.swift
git commit -m "feat(ui): render thinking log and live metrics in generation panel"
```

---

### Task 6: 全量回归

**Files:**
- 无代码改动（仅验证）

- [ ] **Step 1: 全量构建**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete，0 warning。

- [ ] **Step 2: 全量测试（跳过真实模型测试类）**

Run: `swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests 2>&1 | grep -E "Executed|failed" | tail -5`
Expected: 全绿 0 failures；测试数 = 上期 352 + 新增（MarkedStreamBuffer 7 + AgenticPrompts 3 + AgenticEmbedding 2 + GenerateViewModel 3）= 367。

- [ ] **Step 3: 收尾检查**

- `MarkedStreamBuffer.swift` ≤ 300 行、`GenThinkingLogView.swift` ≤ 300 行。
- 备忘录追加交付要点（管线、标记、指标、日志、停止、测试数）。
- `swift run` 冒烟留给用户手动（本地模型推理不跑）。

- [ ] **Step 4: Commit（若工作区有本功能相关未提交改动）**

```bash
git add <本功能相关文件>
git commit -m "chore: generation progress visualization delivered (full suite green)"
```
若无可提交内容则跳过（前序 Task 已逐项提交）。

---

## 自检记录（实现时复查）

- **Spec 覆盖**：GenThought + thought 事件（Task 1/3）✓；MarkedStreamBuffer + extractMarkedBody + 标记指令（Task 2/3）✓；VM thinkingLog/streamStats/thought 路由（Task 4）✓；左侧面板日志+指标+停止（Task 5）✓；全量回归（Task 6）✓。
- **类型一致性**：`GenThought(id:kind:message:detail:status:)` 成员顺序全计划一致；`ThinkingLogItem` / `StreamStats` 字段在 Task 4 测试与实现一致；`applyProgress` 对 `.thought` 的 upsert 语义在测试与实现一致（同 id 更新 message/status，保留首次 elapsedAt）。
- **风险**：生成器接入后 `onProgress?.thought` 不改变 LLM 调用序列（SequenceMockClient 只数 complete/stream 调用），既有调用序列断言不受影响；`MarkedStreamBuffer` 对无标记响应回退全量，既有 mock 响应无需加标记。`embedWord` 改 `async throws` 后，`generateViaRewrite` 内调用处需 `try await`。
