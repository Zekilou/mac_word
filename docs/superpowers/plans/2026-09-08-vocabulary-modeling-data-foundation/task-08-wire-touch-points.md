# Task 8：接入点写入事件（5 主动 + 1 被动）

**Files:**
- Create: `Sources/WordRecitingApp/ECS/RegionRecorder.swift`
- Modify: `Sources/WordRecitingApp/UI/StudyViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyInitViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateViewModel+ArticleWords.swift`
- Modify: `Sources/WordRecitingApp/RSS/RSSViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/SystemDictionaryViewModel.swift`
- Test: `Tests/WordRecitingAppTests/ECS/RegionRecorderTests.swift`（新建）
- Test: `Tests/WordRecitingAppTests/ECS/RegionWiringTests.swift`（新建）

**依赖：** Task 4。

**原则：** 事件流是**辅助数据**——记录失败不得打断主流程（词汇状态已写成功）。因此统一走 `RegionRecorder`，内部吞掉错误。

---

- [ ] **Step 1: 写失败测试**

**1a. 新建 `Tests/WordRecitingAppTests/ECS/RegionRecorderTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

final class RegionRecorderTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    func testRecordByLemmaIds() throws {
        try makeLemma("L1", "abandon")
        RegionRecorder(world: world).record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .lookup)

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 1)
    }

    func testRecordBySurfacesResolvesLemmaIds() throws {
        try makeLemma("L1", "abandon")
        RegionRecorder(world: world).record(
            surfaces: ["abandon", "zzzzz"], region: .dictionary(), kind: .markUnknown, trust: 1.0)

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE trust = 1"), 1)
    }

    func testEmptyInputIsNoOp() throws {
        RegionRecorder(world: world).record(
            lemmaIds: [], region: .dictionary(), kind: .lookup)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 0)
    }

    /// 记录失败不抛错（事件流是辅助数据）。
    func testFailureIsSwallowed() throws {
        RegionRecorder(world: world).record(
            lemmaIds: ["L404"], region: .dictionary(), kind: .lookup)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 0)
    }
}
```

**1b. 新建 `Tests/WordRecitingAppTests/ECS/RegionWiringTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

@MainActor
final class RegionWiringTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    // MARK: - 主动：复习做题

    func testStudyRateRecordsQuizEvent() throws {
        try makeLemma("L1", "abandon")
        try world.registry.insertNode(id: "C1", kind: .card, createdAt: Date())

        let vm = StudyViewModel(world: world)
        vm.queue = [CardListItem(
            cardId: "C1", lemmaId: "L1", text: "abandon", definition: nil,
            dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)]
        vm.rate(.good)

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'quiz_correct'"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_region WHERE kind = 'study'"), 1)
    }

    func testStudyAgainRecordsQuizWrong() throws {
        try makeLemma("L1", "abandon")
        try world.registry.insertNode(id: "C1", kind: .card, createdAt: Date())

        let vm = StudyViewModel(world: world)
        vm.queue = [CardListItem(
            cardId: "C1", lemmaId: "L1", text: "abandon", definition: nil,
            dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)]
        vm.rate(.again)

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'quiz_wrong'"), 1)
    }

    // MARK: - 主动：词典查词标记

    func testDictionaryToggleMarkRecordsEvent() throws {
        try makeLemma("L1", "abandon")
        let vm = SystemDictionaryViewModel(world: world)
        vm.toggleMark("abandon")

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'mark_known' AND trust = 1"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_region WHERE kind = 'dictionary'"), 1)
    }

    // MARK: - 被动 + 主动：RSS

    func testRSSPassiveSeenHasZeroTrust() throws {
        try makeLemma("L1", "abandon")
        let defaults = UserDefaults(suiteName: "test-region-\(UUID())")!
        let vm = RSSViewModel(world: world, store: RSSSourceStore(defaults: defaults))
        vm.selectedItem = RSSItem(id: "A1", title: "文章", link: "", summary: "",
                                  content: "", pubDate: nil)
        vm.presentArticle(text: "We abandon the old plan.")

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'seen' AND trust = 0"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_region WHERE kind = 'rss'"), 1)
    }

    func testRSSToggleRecordsHighTrustEvent() throws {
        try makeLemma("L1", "abandon")
        let defaults = UserDefaults(suiteName: "test-region-\(UUID())")!
        let vm = RSSViewModel(world: world, store: RSSSourceStore(defaults: defaults))
        vm.selectedItem = RSSItem(id: "A1", title: "文章", link: "", summary: "",
                                  content: "", pubDate: nil)
        vm.toggle(InitWord(surface: "abandon", lemma: "abandon"))

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE trust = 1 AND event_kind = 'mark_unknown'"), 1)
    }

    // MARK: - 主动：词汇初始化

    func testInitSubmitRecordsBatchEvents() throws {
        try makeLemma("L1", "abandon")
        let vm = VocabularyInitViewModel(world: world)
        vm.words = [InitWord(surface: "abandon", lemma: "abandon")]
        vm.sessionStates = ["abandon": false]
        vm.stage = .ready
        vm.submit()

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE event_kind = 'mark_unknown' AND trust = 1"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_region WHERE kind = 'init'"), 1)
    }
}
```

> RSS 的被动 `seen` 测试需要 `presentArticle(text:)` 可被测试调用：把 `RSSViewModel.swift` 中的 `private func presentArticle(text: String)` 改为 `func presentArticle(text: String)`（内部可见）。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RegionRecorderTests 2>&1 | tail -5`
Run: `swift test --filter RegionWiringTests 2>&1 | tail -5`
Expected: FAIL（`cannot find 'RegionRecorder'` / 事件计数为 0）。

- [ ] **Step 3: 实现统一记录器**

新建 `Sources/WordRecitingApp/ECS/RegionRecorder.swift`：

```swift
import Foundation

/// 统一的事件记录入口：所有接入点都走这里。
/// @ai: 事件流是辅助数据——记录失败不得打断主流程（词汇状态已写成功）。
struct RegionRecorder: Sendable {
    let world: World

    /// 仅登记 region（进入页面时调用）。
    func ensure(_ region: RegionRef) {
        try? world.run(RegionSystem(), context: .ensure(region))
    }

    /// 按 lemma id 记录事件。
    func record(lemmaIds: [EntityID], region: RegionRef, kind: WordEventKind,
                trust: Double? = nil, detail: String? = nil) {
        guard !lemmaIds.isEmpty else { return }
        try? world.run(RegionSystem(), context: .record(
            lemmaIds: lemmaIds, region: region, kind: kind, trust: trust, detail: detail))
    }

    /// 按词面记录事件：解析不到的词静默跳过。
    func record(surfaces: [String], region: RegionRef, kind: WordEventKind,
                trust: Double? = nil, detail: String? = nil) {
        let ids = surfaces.compactMap { try? world.graph.findLemmaId(byTextA: $0) }
        record(lemmaIds: ids, region: region, kind: kind, trust: trust, detail: detail)
    }
}
```

- [ ] **Step 4: 接入 5 个位置**

**4a. `UI/StudyViewModel.swift` — `rate(_:)`**

在 `try world.run(StudySystem(), ...)` 之后、`currentIndex += 1` 之前插入：

```swift
            // 主动做题 → 高可信词事件
            RegionRecorder(world: world).record(
                lemmaIds: [card.lemmaId],
                region: .study(cardId: card.cardId),
                kind: rating.rawValue >= Rating.good.rawValue ? .quizCorrect : .quizWrong)
```

**4b. `UI/SystemDictionaryViewModel.swift` — `toggleMark(_:)`**

在 `try world.run(UserKnownSystem(), ...)` 之后插入：

```swift
            RegionRecorder(world: world).record(
                surfaces: [word], region: .dictionary(),
                kind: known ? .markKnown : .markUnknown, trust: 1.0)
```

**4c. `UI/Init/VocabularyInitViewModel.swift` — 新增 sessionId + `submit()`**

在依赖区追加：

```swift
    /// 本次初始化会话 id：用于把本会话的词事件归入同一 region。
    private let sessionId: EntityID = UUID().uuidString
```

在 `submit()` 的 `try world.run(UserKnownSystem(), context: .batch(...))` 之后插入：

```swift
            let region = RegionRef.initSession(sessionId: sessionId)
            let recorder = RegionRecorder(world: world)
            recorder.ensure(region)
            for item in batchWords {
                recorder.record(lemmaIds: [item.word].compactMap {
                    try? world.graph.findLemmaId(byTextA: $0)
                }, region: region,
                   kind: item.known ? .markKnown : .markUnknown, trust: 1.0)
            }
```

**4d. `RSS/RSSViewModel.swift`**

- 把 `private func presentArticle(text: String)` 改为 `func presentArticle(text: String)`。
- 在类内追加私有 helper：

```swift
    /// 当前文章的显示上下文（region id 稳定可复用）。
    private var currentRegion: RegionRef {
        RegionRef.rss(articleId: selectedItem?.id ?? "unknown", title: selectedItem?.title)
    }
```

- `presentArticle(text:)` 中 `.markSeen` 之后插入（**被动，trust = 0**）：

```swift
        RegionRecorder(world: world).record(
            surfaces: seenWords, region: currentRegion, kind: .seen, trust: 0.0)
```

- `toggle(_ word:)` 中把 `switch` 结果同时用于事件种类：

```swift
        let eventKind: WordEventKind
        switch markState(for: word) {
        case .known:
            op = .markUnknown(lemmaId: lemmaId, source: "rss")
            eventKind = .markUnknown
        case .unknown:
            op = .markKnown(lemmaId: lemmaId, source: "rss")
            eventKind = .markKnown
        case .seen, .pending, .learning:
            op = .markUnknown(lemmaId: lemmaId, source: "rss")
            eventKind = .markUnknown
        }
        do {
            try world.run(UserKnownSystem(), context: op)
            RegionRecorder(world: world).record(
                lemmaIds: [lemmaId], region: currentRegion, kind: eventKind, trust: 1.0)
            reloadStates()
        } catch {
```

- `setExtreme(_ word:known:)` 中 `try world.run(UserKnownSystem(), ...)` 之后插入：

```swift
            RegionRecorder(world: world).record(
                surfaces: [word.lemma], region: currentRegion,
                kind: known ? .markKnown : .markUnknown, trust: 1.0)
```

**4e. `UI/Creation/GenerateViewModel+ArticleWords.swift`**

- 追加私有 helper：

```swift
    /// 当前生成文章的显示上下文（region id 稳定可复用）。
    private var currentArticleRegion: RegionRef {
        RegionRef.generate(articleId: loadedBodyKey ?? "session", title: nil)
    }
```

- `persistArticleWordState(_:)` 中 `try world.run(UserKnownSystem(), ...)` 之后插入：

```swift
        RegionRecorder(world: world).record(
            lemmaIds: [token.lemmaId].compactMap { $0 },
            region: currentArticleRegion,
            kind: known ? .markKnown : .markUnknown, trust: 1.0)
```

- `ensureArticleWords(body:spans:)` 中（`articleWords` 赋值后）追加一次 region 登记：

```swift
        RegionRecorder(world: world).ensure(currentArticleRegion)
```

**4f. 生成文章的接线测试**（在既有 `Tests/WordRecitingAppTests/UI/GenerateArticleWordsTests.swift` 中追加一条）：

```swift
    func testSetArticleWordExtremeRecordsEvent() throws {
        // 复用本文件 setUp 的 world / vm 构造方式
        let eventCount = try world.database.dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_word_event WHERE trust = 1
                """)
        }
        XCTAssertGreaterThan(eventCount ?? 0, 0)
    }
```

> 该文件已有「生成正文 → ensureArticleWords → setArticleWordExtreme」的测试夹具，把上面的断言追加到那条测试末尾即可；若没有现成夹具，则构造 `GeneratedArticle` 后调用 `vm.ensureArticleWords(body:spans:)` 再 `vm.setArticleWordExtreme(token, known: false)`。

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter RegionRecorderTests 2>&1 | tail -5`
Run: `swift test --filter RegionWiringTests 2>&1 | tail -5`
Expected: 全部 PASS。

- [ ] **Step 6: 回归受影响模块**

Run: `swift test --filter StudyViewModel 2>&1 | tail -5`
Run: `swift test --filter RSSViewModelTests 2>&1 | tail -5`
Run: `swift test --filter VocabularyInitViewModelTests 2>&1 | tail -5`
Run: `swift test --filter SystemDictionaryTests 2>&1 | tail -5`
Run: `swift test --filter GenerateArticleWordsTests 2>&1 | tail -5`
Expected: 全 PASS。若既有测试断言了 `comp_word_event` 不存在的旧行为，更新为「存在且计数正确」。

- [ ] **Step 7: Commit**

```bash
git add Sources/WordRecitingApp/ECS/RegionRecorder.swift \
        Sources/WordRecitingApp/UI/StudyViewModel.swift \
        Sources/WordRecitingApp/UI/SystemDictionaryViewModel.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyInitViewModel.swift \
        Sources/WordRecitingApp/RSS/RSSViewModel.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateViewModel+ArticleWords.swift \
        Tests/WordRecitingAppTests/ECS/RegionRecorderTests.swift \
        Tests/WordRecitingAppTests/ECS/RegionWiringTests.swift \
        Tests/WordRecitingAppTests/UI/GenerateArticleWordsTests.swift
git commit -m "feat(app): 五个接入点写入带 region 与可信度的词事件"
```

---
