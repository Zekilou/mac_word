# Task 6：复习页改造（队列判定 + 卡片背面）

**Files:**
- Modify: `Sources/WordRecitingApp/ECS/GraphQueries+Study.swift`（到期队列排除判定）
- Modify: `Sources/WordRecitingApp/UI/StudyViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/StudyView.swift`
- Test: `Tests/WordRecitingAppTests/ECS/GraphQueriesStudyBeliefTests.swift`（追加）
- Test: `Tests/WordRecitingAppTests/UI/StudyViewModelTests.swift`（新建）

**依赖：** Task 1。

**审计对照（README 表格第 7 行）：** 队列按 `mastery ≥ 1.999` 排除「已会」，背面无模型信息。改法：排除判定改「显式标记会 **或** 模型高置信」；背面加概率 / 词频带 / 事件摘要。

---

- [ ] **Step 1: 写失败测试**

**1a. 在 `Tests/WordRecitingAppTests/ECS/GraphQueriesStudyBeliefTests.swift` 末尾追加：**

```swift
    func testDueCardsExcludesHighBeliefWords() throws {
        try seedCard(lemmaId: "L1", cardId: "C1", text: "abandon", belief: 0.95)

        XCTAssertTrue(try world.graph.dueCards().isEmpty)
    }

    func testDueCardsKeepsLowBeliefWords() throws {
        try seedCard(lemmaId: "L2", cardId: "C2", text: "ability", belief: 0.40)

        XCTAssertEqual(try world.graph.dueCards().count, 1)
    }

    func testDueCardsStillExcludesExplicitlyKnownWords() throws {
        try seedCard(lemmaId: "L3", cardId: "C3", text: "zebra", belief: 0.30)
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L3", mastery: 2.0, seenCount: 0,
            source: "init", updatedAt: Date()))

        XCTAssertTrue(try world.graph.dueCards().isEmpty)
    }
```

**1b. 新建 `Tests/WordRecitingAppTests/UI/StudyViewModelTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

@MainActor
final class StudyViewModelTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeCard(_ cardId: String) throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.insertNode(id: cardId, kind: .card, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: "放弃", language: nil))
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "test"))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.44, opportunities: 2,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
    }

    private func cardItem(_ cardId: String) -> CardListItem {
        CardListItem(cardId: cardId, lemmaId: "L1", text: "abandon", definition: "放弃",
                     dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)
    }

    func testSummaryTextLabelsAndOrder() {
        let text = StudyViewModel.summaryText(counts: ["seen": 3, "mark_unknown": 1])
        XCTAssertEqual(text, "标记不会 1 次 · 出现过 3 次")
    }

    func testSummaryTextIsNilWhenEmpty() {
        XCTAssertNil(StudyViewModel.summaryText(counts: [:]))
    }

    func testRefreshCurrentProfileLoadsCardInfo() throws {
        try makeCard("C1")
        let vm = StudyViewModel(world: world)
        vm.queue = [cardItem("C1")]

        vm.refreshCurrentProfile()

        XCTAssertEqual(vm.currentBelief ?? 0, 0.44, accuracy: 0.0001)
        XCTAssertEqual(vm.currentBand, 2)
        XCTAssertEqual(vm.currentRank, 1001)
        XCTAssertNil(vm.currentEventSummary)
    }

    func testRefreshCurrentProfileClearsWithoutCard() throws {
        let vm = StudyViewModel(world: world)
        vm.queue = []
        vm.refreshCurrentProfile()
        XCTAssertNil(vm.currentBelief)
        XCTAssertNil(vm.currentBand)
    }

    func testRateAdvancesAndReloadsProfile() throws {
        try makeCard("C1")
        try world.registry.insertNode(id: "C2", kind: .card, createdAt: Date())
        let vm = StudyViewModel(world: world)
        vm.queue = [cardItem("C1"), cardItem("C2")]
        vm.refreshCurrentProfile()

        vm.rate(.good)

        XCTAssertEqual(vm.currentEventSummary, "答对 1 次")
        XCTAssertEqual(vm.currentBelief ?? 0, 0.44, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GraphQueriesStudyBeliefTests 2>&1 | tail -6`
Run: `swift test --filter StudyViewModelTests 2>&1 | tail -6`
Expected: FAIL（高置信词仍在队列 / 缺 `summaryText`）。

- [ ] **Step 3: 实现**

**3a. `GraphQueries+Study.swift` 的 `dueCards`：**

- 文档注释改为：

```swift
    /// 到期卡片队列（含从未学过的"新卡"）：按到期时间升序（最紧迫优先）。
    /// **排除**「用户显式标记会（mastery ≥ 1.999）」或「模型高置信（belief ≥ beliefCutoff）」的词。
    /// @ai: 概率主口径——模型认为已经会的词不再进背诵队列；要复习需先改回不会。
```

- WHERE 段追加一行：

```sql
              AND (mb.belief IS NULL OR mb.belief < ?)
```

- 参数与阈值改为：

```swift
            let knownCutoff = 1.999
            // 与 WordMarkState.knownThreshold 对齐的模型高置信阈值。
            let beliefCutoff = 0.90
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: [now, knownCutoff, beliefCutoff, limit])
```

**3b. `StudyViewModel.swift`：**

- 状态区追加：

```swift
    /// 当前卡的 BKT 后验概率（nil = 尚无事件）。
    private(set) var currentBelief: Double?
    /// 当前卡的词频带 / 全表排名。
    private(set) var currentBand: Int?
    private(set) var currentRank: Int?
    /// 当前卡的事件摘要，如 "标记不会 1 次 · 出现过 3 次"。
    private(set) var currentEventSummary: String?
```

- `reload()` 末尾追加 `refreshCurrentProfile()`。
- `rate(_:)` 中 `currentIndex += 1; isFront = true` 之后、`stats = ...` 之前追加 `refreshCurrentProfile()`。
- 追加方法：

```swift
    /// 刷新当前卡的模型信息（后验概率 / 词频坐标 / 事件摘要）。
    func refreshCurrentProfile() {
        guard let card = currentCard else {
            currentBelief = nil
            currentBand = nil
            currentRank = nil
            currentEventSummary = nil
            return
        }
        currentBelief = try? world.graph.masteryBelief(lemmaId: card.lemmaId)
        let frequency = try? world.graph.lemmaFrequency(lemmaId: card.lemmaId)
        currentBand = frequency?.band
        currentRank = frequency?.freqRank
        let counts = (try? world.graph.wordEventCountsByKind(lemmaId: card.lemmaId)) ?? [:]
        currentEventSummary = Self.summaryText(counts: counts)
    }

    /// 事件计数 → 摘要文案（纯函数，可单测）。
    nonisolated static func summaryText(counts: [String: Int]) -> String? {
        let order: [WordEventKind] = [
            .quizCorrect, .quizWrong, .markKnown, .markUnknown, .lookup, .seen
        ]
        let parts = order.compactMap { kind -> String? in
            guard let count = counts[kind.rawValue], count > 0 else { return nil }
            return "\(EventTimelinePresenter.kindLabel(kind)) \(count) 次"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
```

**3c. `StudyView.swift` 的 `flashcardArea(_:)` 背面分支：在释义与「点击翻回正面」之间插入：**

```swift
                        HStack(spacing: 10) {
                            if let belief = vm.currentBelief {
                                Text(MasteryPresentation.percentText(belief))
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(stateColor(vm.currentBelief))
                                    .help(MasteryPresentation.helpText(belief))
                            } else {
                                Text(MasteryPresentation.noDataText)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(FrequencyBandPresentation.bandLabel(vm.currentBand))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(FrequencyBandPresentation.helpText(
                                    band: vm.currentBand, rank: vm.currentRank))
                        }
                        if let summary = vm.currentEventSummary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
```

- 在 `StudyView` 内追加颜色辅助：

```swift
    private func stateColor(_ belief: Double?) -> Color {
        WordMarkState.from(belief: belief, mastery: nil, seenCount: 0).color
    }
```

**3d. 评分按钮防误触（审计 P1）：**

- 评分按钮区在「不认识」与其余三键之间加视觉分隔：

```swift
            HStack(spacing: 12) {
                ratingButton("不认识", rating: .again, color: .red) {
                    Image(systemName: "xmark")
                }
                Spacer().frame(width: 16)
                ratingButton("有点难", rating: .hard, color: .orange) {
                    Image(systemName: "minus")
                }
                ratingButton("认识", rating: .good, color: .green) {
                    Image(systemName: "checkmark")
                }
                ratingButton("很熟", rating: .easy, color: .blue) {
                    Image(systemName: "star.fill")
                }
            }
```

- `ratingButton` 的 `VStack` 里补一行快捷键提示：

```swift
                Text(keyLabel(rating))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
```

- 追加：

```swift
    private func keyLabel(_ rating: Rating) -> String {
        switch rating {
        case .again: return "1"
        case .hard: return "2"
        case .good: return "3"
        case .easy: return "4"
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GraphQueriesStudyBeliefTests 2>&1 | tail -6`
Run: `swift test --filter StudyViewModelTests 2>&1 | tail -6`
Expected: 全 PASS。

- [ ] **Step 5: 回归复习相关**

Run: `swift test --filter StudySystemTests 2>&1 | tail -5`
Run: `swift test --filter GraphQueriesStudyTests 2>&1 | tail -5`
Expected: 全 PASS。若既有队列测试依赖「高置信词仍进队列」的旧行为，按新口径更新。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/ECS/GraphQueries+Study.swift \
        Sources/WordRecitingApp/UI/StudyViewModel.swift \
        Sources/WordRecitingApp/UI/StudyView.swift \
        Tests/WordRecitingAppTests/ECS/GraphQueriesStudyBeliefTests.swift \
        Tests/WordRecitingAppTests/UI/StudyViewModelTests.swift
git commit -m "refactor(ui): 复习队列改概率排除并展示模型信息"
```

---
