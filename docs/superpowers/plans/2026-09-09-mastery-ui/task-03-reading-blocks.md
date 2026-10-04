# Task 3：三处阅读词块改造（初始化 / RSS / 生成文章）

**Files:**
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyInitViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyInitView.swift`
- Modify: `Sources/WordRecitingApp/RSS/RSSViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/ReadingView.swift`
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateViewModel+ArticleWords.swift`
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateView+ReadText.swift`
- Test: `Tests/WordRecitingAppTests/UI/VocabularyInitViewModelTests.swift`（追加）
- Test: `Tests/WordRecitingAppTests/RSS/RSSViewModelTests.swift`（追加）
- Test: `Tests/WordRecitingAppTests/UI/GenerateArticleWordsTests.swift`（追加）

**依赖：** Task 1。

**审计对照（README 表格第 3 行）：** 三处词块各自有一份 `helpText`，文案在讲旧的 0/1/2 语义，判定也不看概率。改法：三处 VM 都加载 `beliefByLemma` 并传进 `WordMarkState.from`；三处 helpText 改概率文案。

---

- [ ] **Step 1: 写失败测试**

**1a. 在 `Tests/WordRecitingAppTests/UI/VocabularyInitViewModelTests.swift` 末尾追加：**

```swift
    func testMarkStateIsDrivenByBelief() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 0,
            source: "init", updatedAt: Date()))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.1, opportunities: 3,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        let vm = VocabularyInitViewModel(world: world)
        vm.loadMastery()

        let word = InitWord(surface: "abandon", lemma: "abandon")
        XCTAssertEqual(vm.markState(for: word), .unknown)
    }

    func testMarkStateFallsBackToMasteryWithoutBelief() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 0,
            source: "init", updatedAt: Date()))

        let vm = VocabularyInitViewModel(world: world)
        vm.loadMastery()

        let word = InitWord(surface: "abandon", lemma: "abandon")
        XCTAssertEqual(vm.markState(for: word), .known)
    }
```

**1b. 在 `Tests/WordRecitingAppTests/RSS/RSSViewModelTests.swift` 末尾追加：**

```swift
    func testMarkStateIsDrivenByBelief() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 0,
            source: "rss", updatedAt: Date()))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.1, opportunities: 3,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        let vm = RSSViewModel(world: world)
        vm.reloadStates()

        XCTAssertEqual(vm.markState(for: InitWord(surface: "abandon", lemma: "abandon")), .unknown)
    }
```

**1c. 在 `Tests/WordRecitingAppTests/UI/GenerateArticleWordsTests.swift` 末尾追加：**

```swift
    func testArticleMarkStateIsDrivenByBelief() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 0,
            source: "reading", updatedAt: Date()))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.1, opportunities: 3,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        // 复用本文件已有的 vm 构造方式
        vm.loadWordMastery()
        let token = ArticleWordToken(
            id: 0, surface: "abandon", lemma: "abandon",
            start: 0, end: 7, isTarget: true, lemmaId: "L1")

        XCTAssertEqual(vm.articleMarkState(for: token), .unknown)
    }
```

> 若该文件里的 VM 变量名或构造方式不同，按文件内既有写法调整。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter VocabularyInitViewModelTests 2>&1 | tail -6`
Run: `swift test --filter RSSViewModelTests 2>&1 | tail -6`
Run: `swift test --filter GenerateArticleWordsTests 2>&1 | tail -6`
Expected: FAIL（判定仍返回 `.known`）。

- [ ] **Step 3: 实现**

**3a. `VocabularyInitViewModel.swift`：**

- 属性区追加：

```swift
    /// BKT 后验概率（lemma → 概率）：判定主口径。
    private(set) var beliefByLemma: [String: Double] = [:]
```

- `loadMastery()` 追加一行：

```swift
    func loadMastery() {
        masteryByLemma = (try? world.graph.knownLemmaMastery()) ?? [:]
        beliefByLemma = (try? world.graph.allMasteryBeliefs()) ?? [:]
    }
```

- `markState(for:)` 的返回改为：

```swift
        return WordMarkState.from(
            belief: beliefByLemma[lemmaId],
            mastery: masteryByLemma[lemmaId],
            seenCount: seenByLemma[lemmaId] ?? 0)
```

**3b. `RSSViewModel.swift`：**

- 属性区追加：

```swift
    /// BKT 后验概率（lemma → 概率）：判定主口径。
    private(set) var beliefByLemma: [String: Double] = [:]
```

- `reloadStates()` 追加一行：

```swift
    func reloadStates() {
        masteryByLemma = (try? world.graph.knownLemmaMastery()) ?? [:]
        seenByLemma = (try? world.graph.allLemmaSeenCounts()) ?? [:]
        beliefByLemma = (try? world.graph.allMasteryBeliefs()) ?? [:]
    }
```

- `markState(for:)` 的返回改为：

```swift
        return WordMarkState.from(
            belief: beliefByLemma[lemmaId],
            mastery: masteryByLemma[lemmaId],
            seenCount: seenByLemma[lemmaId] ?? 0)
```

**3c. `GenerateViewModel+ArticleWords.swift`：**

- `GenerateViewModel.swift` 属性区追加：

```swift
    /// BKT 后验概率（lemma → 概率）：判定主口径。
    var beliefByLemma: [String: Double] = [:]
```

- `loadWordMastery()` 追加一行：

```swift
    func loadWordMastery() {
        masteryByLemma = (try? world.graph.knownLemmaMastery()) ?? [:]
        seenByLemma = (try? world.graph.allLemmaSeenCounts()) ?? [:]
        beliefByLemma = (try? world.graph.allMasteryBeliefs()) ?? [:]
    }
```

- `articleMarkState(for:)` 的返回改为：

```swift
        return WordMarkState.from(
            belief: beliefByLemma[token.lemma],
            mastery: masteryByLemma[token.lemma],
            seenCount: seenByLemma[token.lemma] ?? 0)
```

**3d. 三处 `helpText` 改概率文案。**

`VocabularyInitView.swift` 的 `helpText(for:)` 整体替换：

```swift
    private func helpText(for state: WordMarkState) -> String {
        switch state {
        case .known: return "模型认为已会（点击标记为不会）"
        case .unknown: return "模型认为不会（点击切换为会 / 恢复无记录）"
        case .learning(let belief): return "\(MasteryPresentation.helpText(belief))；点击需确认后改为两端极值"
        case .seen: return "出现过未确认，模型尚无概率（点击标记为不会）"
        case .pending: return "无记录（点击标记为不会）"
        }
    }
```

`ReadingView.swift` 的 `helpText(for:)` 整体替换：

```swift
    private func helpText(for state: WordMarkState) -> String {
        switch state {
        case .known: return "模型认为已会（点击标记为不会）"
        case .unknown: return "模型认为不会（点击切换为会）"
        case .learning(let belief): return "\(MasteryPresentation.helpText(belief))；点击需确认后改为两端极值"
        case .seen: return "出现过未确认，模型尚无概率（点击标记为不会）"
        case .pending: return "无记录（点击标记为不会）"
        }
    }
```

`GenerateView+ReadText.swift` 的 `articleWordHelpText(for:)` 整体替换：

```swift
    private func articleWordHelpText(for state: WordMarkState) -> String {
        switch state {
        case .known: return "模型认为已会（点击标记为不会）"
        case .unknown: return "模型认为不会（点击标记为会）"
        case .learning(let belief): return "\(MasteryPresentation.helpText(belief))；点击需确认后改为两端极值"
        case .seen: return "出现过未确认，模型尚无概率（点击标记为不会）"
        case .pending: return "无记录（点击标记为不会）"
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter VocabularyInitViewModelTests 2>&1 | tail -6`
Run: `swift test --filter RSSViewModelTests 2>&1 | tail -6`
Run: `swift test --filter GenerateArticleWordsTests 2>&1 | tail -6`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/UI/Init/VocabularyInitViewModel.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyInitView.swift \
        Sources/WordRecitingApp/RSS/RSSViewModel.swift \
        Sources/WordRecitingApp/UI/ReadingView.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateViewModel+ArticleWords.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateView+ReadText.swift \
        Tests/WordRecitingAppTests/UI/VocabularyInitViewModelTests.swift \
        Tests/WordRecitingAppTests/RSS/RSSViewModelTests.swift \
        Tests/WordRecitingAppTests/UI/GenerateArticleWordsTests.swift
git commit -m "refactor(ui): 三处阅读词块改概率口径"
```

---
