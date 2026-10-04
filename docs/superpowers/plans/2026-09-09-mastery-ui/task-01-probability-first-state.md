# Task 1：`WordMarkState` 概率主口径（判定核心）

**Files:**
- Modify: `Sources/WordRecitingApp/UI/WordMarkState.swift`
- Create: `Sources/WordRecitingApp/UI/Presentation/MasteryPresentation.swift`
- Modify: `Sources/WordRecitingApp/ECS/GraphQueryTypes.swift`（`CardListItem` 加 `belief`）
- Modify: `Sources/WordRecitingApp/ECS/GraphQueries+Study.swift`（两处 SQL 加 `comp_mastery_belief` JOIN）
- Test: `Tests/WordRecitingAppTests/UI/WordMarkStateTests.swift`（新建）
- Test: `Tests/WordRecitingAppTests/UI/Presentation/MasteryPresentationTests.swift`（新建）
- Test: `Tests/WordRecitingAppTests/ECS/GraphQueriesStudyBeliefTests.swift`（新建）

**依赖：** 阶段二已落地（`comp_mastery_belief` + `GraphQueries+Mastery`）。

**这是全应用唯一的词块判定核心。** 改完它，六个页面的判定同时具备概率能力（各页接线在 Task 2–6）。

---

- [ ] **Step 1: 写失败测试**

**1a. 新建 `Tests/WordRecitingAppTests/UI/WordMarkStateTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

final class WordMarkStateTests: XCTestCase {

    private func assertLearning(_ state: WordMarkState, _ expected: Double,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .learning(let belief) = state else {
            XCTFail("expected .learning, got \(state)", file: file, line: line)
            return
        }
        XCTAssertEqual(belief, expected, accuracy: 0.0001, file: file, line: line)
    }

    // MARK: - 概率主口径

    func testBeliefDrivesState() {
        XCTAssertEqual(WordMarkState.from(belief: 0.95, mastery: 1.0, seenCount: 0), .known)
        XCTAssertEqual(WordMarkState.from(belief: 0.10, mastery: 2.0, seenCount: 0), .unknown)
        assertLearning(WordMarkState.from(belief: 0.5, mastery: 2.0, seenCount: 0), 0.5)
    }

    func testThresholdsAreInclusive() {
        XCTAssertEqual(WordMarkState.from(belief: 0.85, mastery: nil, seenCount: 0), .known)
        XCTAssertEqual(WordMarkState.from(belief: 0.851, mastery: nil, seenCount: 0), .known)
        XCTAssertEqual(WordMarkState.from(belief: 0.20, mastery: nil, seenCount: 0), .unknown)
        XCTAssertEqual(WordMarkState.from(belief: 0.199, mastery: nil, seenCount: 0), .unknown)
    }

    func testBeliefOverridesExplicitMastery() {
        // 用户标了「会」，但模型概率低 → 以概率为准
        XCTAssertEqual(WordMarkState.from(belief: 0.15, mastery: 2.0, seenCount: 3), .unknown)
    }

    // MARK: - 无概率时回退显式标记

    func testFallsBackToMasteryWhenNoBelief() {
        XCTAssertEqual(WordMarkState.from(belief: nil, mastery: 2.0, seenCount: 0), .known)
        XCTAssertEqual(WordMarkState.from(belief: nil, mastery: 1.0, seenCount: 0), .unknown)
        XCTAssertEqual(WordMarkState.from(belief: nil, mastery: nil, seenCount: 3), .seen)
        XCTAssertEqual(WordMarkState.from(belief: nil, mastery: nil, seenCount: 0), .pending)
    }

    func testMasteryMapsLinearlyToBeliefInLearningBand() {
        assertLearning(WordMarkState.from(belief: nil, mastery: 1.5, seenCount: 0), 0.5)
        assertLearning(WordMarkState.from(belief: nil, mastery: 1.2, seenCount: 0), 0.2)
    }

    // MARK: - 展示

    func testLearningLabelShowsPercent() {
        XCTAssertEqual(WordMarkState.learning(0.5).label, "学习中 50%")
    }

    func testLabels() {
        XCTAssertEqual(WordMarkState.known.label, "已会")
        XCTAssertEqual(WordMarkState.unknown.label, "不会")
        XCTAssertEqual(WordMarkState.seen.label, "出现过")
        XCTAssertEqual(WordMarkState.pending.label, "无记录")
    }

    func testThresholdsAreExposed() {
        XCTAssertEqual(WordMarkState.knownThreshold, 0.85, accuracy: 0.0001)
        XCTAssertEqual(WordMarkState.unknownThreshold, 0.20, accuracy: 0.0001)
    }
}
```

**1b. 新建 `Tests/WordRecitingAppTests/UI/Presentation/MasteryPresentationTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

final class MasteryPresentationTests: XCTestCase {

    func testPercentTextClampsAndRounds() {
        XCTAssertEqual(MasteryPresentation.percentText(0.847), "85%")
        XCTAssertEqual(MasteryPresentation.percentText(0.0), "0%")
        XCTAssertEqual(MasteryPresentation.percentText(1.0), "100%")
        XCTAssertEqual(MasteryPresentation.percentText(1.4), "100%")
        XCTAssertEqual(MasteryPresentation.percentText(-0.2), "0%")
    }

    func testLevelIndexBoundaries() {
        XCTAssertEqual(MasteryPresentation.levelIndex(0.34), 0)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.35), 1)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.69), 1)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.70), 2)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.89), 2)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.90), 3)
    }

    func testLevelLabels() {
        XCTAssertEqual(MasteryPresentation.levelLabel(0.1), "低")
        XCTAssertEqual(MasteryPresentation.levelLabel(0.5), "中")
        XCTAssertEqual(MasteryPresentation.levelLabel(0.8), "较高")
        XCTAssertEqual(MasteryPresentation.levelLabel(0.95), "高")
    }

    func testHelpTextStatesUncertainty() {
        XCTAssertTrue(MasteryPresentation.helpText(0.8).contains("不是精确测量"))
        XCTAssertTrue(MasteryPresentation.helpText(0.8).contains("85%"))
    }
}

final class FrequencyBandPresentationTests: XCTestCase {

    func testBandLabel() {
        XCTAssertEqual(FrequencyBandPresentation.bandLabel(1), "1k 带")
        XCTAssertEqual(FrequencyBandPresentation.bandLabel(25), "25k 带")
        XCTAssertEqual(FrequencyBandPresentation.bandLabel(0), "表外")
        XCTAssertEqual(FrequencyBandPresentation.bandLabel(nil), "—")
    }

    func testRankText() {
        XCTAssertEqual(FrequencyBandPresentation.rankText(1001), "全表第 1001 位")
        XCTAssertNil(FrequencyBandPresentation.rankText(0))
        XCTAssertNil(FrequencyBandPresentation.rankText(nil))
    }

    func testHelpTextIsHonest() {
        XCTAssertTrue(FrequencyBandPresentation.helpText(band: 2, rank: 1001).contains("参考坐标"))
        XCTAssertTrue(FrequencyBandPresentation.helpText(band: nil, rank: nil).contains("没有词频坐标"))
    }
}
```

**1c. 新建 `Tests/WordRecitingAppTests/ECS/GraphQueriesStudyBeliefTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

/// 复习相关查询要把 BKT 后验一起带出来。
final class GraphQueriesStudyBeliefTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func seedCard(lemmaId: String, cardId: String, text: String, belief: Double?) throws {
        let now = Date()
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: now)
        try world.registry.insertNode(id: cardId, kind: .card, createdAt: now)
        try world.registry.upsertComponent(TextComponent(
            entityId: lemmaId, textA: text, textB: "释义", language: nil))
        try world.registry.insertEdge(id: "edge-\(cardId)", srcId: cardId, dstId: lemmaId,
                                      rel: .instantiates, createdAt: now)
        if let belief {
            try world.registry.upsertComponent(MasteryBeliefComponent(
                entityId: lemmaId, belief: belief, opportunities: 2,
                lastEventAt: nil, updatedAt: now, paramsVersion: "bkt-1"))
        }
    }

    func testDueCardsCarriesBelief() throws {
        try seedCard(lemmaId: "L1", cardId: "C1", text: "abandon", belief: 0.42)

        let cards = try world.graph.dueCards()

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].belief ?? 0, 0.42, accuracy: 0.0001)
    }

    func testCardForLemmaCarriesBelief() throws {
        try seedCard(lemmaId: "L1", cardId: "C1", text: "abandon", belief: 0.42)

        XCTAssertEqual(try world.graph.cardForLemma("L1")?.belief ?? 0, 0.42, accuracy: 0.0001)
    }

    func testBeliefIsNilWithoutModelData() throws {
        try seedCard(lemmaId: "L2", cardId: "C2", text: "ability", belief: nil)

        XCTAssertNil(try world.graph.dueCards().first?.belief)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter WordMarkStateTests 2>&1 | tail -6`
Run: `swift test --filter MasteryPresentationTests 2>&1 | tail -6`
Run: `swift test --filter GraphQueriesStudyBeliefTests 2>&1 | tail -6`
Expected: FAIL（`extra argument 'belief' in call` / `cannot find 'MasteryPresentation'` / `value of type 'CardListItem' has no member 'belief'`）。

- [ ] **Step 3: 实现**

**3a. 覆盖 `Sources/WordRecitingApp/UI/WordMarkState.swift`：**

```swift
import SwiftUI

/// 词块显示状态（初始化 / RSS / 生成文章 / 词表 / 卡片浏览 / 词典共用）。
/// **概率主口径**：有 BKT 后验概率时按概率档位判定；没有概率才回退到用户显式标记。
/// @ai: `.learning` 携带的是**概率（0~1）**，不再是旧的 mastery（1~2）。
enum WordMarkState: Equatable {
    /// 已会（概率 ≥ knownThreshold，绿）。
    case known
    /// 不会（概率 ≤ unknownThreshold，红）。
    case unknown
    /// 学习中（携带概率 0~1，颜色按概率连续渐变）。
    case learning(Double)
    /// 出现过未确认（蓝）——被动看到且模型还没有概率。
    case seen
    /// 无记录未见过（灰，待标记）。
    case pending

    /// 概率档位阈值（全应用唯一定义处，禁止各页散落魔法数字）。
    static let knownThreshold = 0.85
    static let unknownThreshold = 0.20

    /// 概率主口径判定：有后验概率 → 概率档位；无概率 → 回退显式标记。
    static func from(belief: Double?, mastery: Double?, seenCount: Int) -> WordMarkState {
        guard let belief else {
            return from(mastery: mastery, seenCount: seenCount)
        }
        if belief >= knownThreshold { return .known }
        if belief <= unknownThreshold { return .unknown }
        return .learning(belief)
    }

    /// 旧口径兜底：用户显式标记（mastery 0/1/2）。仅在模型还没有概率时使用。
    static func from(mastery: Double?, seenCount: Int) -> WordMarkState {
        guard let m = mastery, m > 0 else {
            return seenCount > 0 ? .seen : .pending
        }
        if m >= 1.999 { return .known }
        if m <= 1.001 { return .unknown }
        return .learning(m - 1.0)
    }

    /// 词块底色：会→绿 / 不会→红 / 学习中→概率渐变（0 红 → 0.5 黄 → 1 绿）/ 出现过→蓝 / 无记录→灰。
    var color: Color {
        switch self {
        case .known: return .green
        case .unknown: return .red
        case .learning(let belief):
            let t = min(1, max(0, belief))
            let hue = t * 120 / 360
            return Color(hue: hue, saturation: 0.8, brightness: 0.8)
        case .seen: return .blue
        case .pending: return .gray
        }
    }

    /// 中文标签（图例 / 列表 / 计数用）。
    var label: String {
        switch self {
        case .known: return "已会"
        case .unknown: return "不会"
        case .learning(let belief): return "学习中 \(MasteryPresentation.percentText(belief))"
        case .seen: return "出现过"
        case .pending: return "无记录"
        }
    }
}
```

**3b. 新建 `Sources/WordRecitingApp/UI/Presentation/MasteryPresentation.swift`：**

```swift
import Foundation

/// 掌握度概率的展示格式化（纯函数，可单测；不放 SwiftUI 依赖）。
enum MasteryPresentation {

    /// 百分比文案，如 "85%"。输入钳制到 [0,1]。
    static func percentText(_ belief: Double) -> String {
        let clamped = min(max(belief, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// 档位序号 0..3（视图据此选颜色）。
    static func levelIndex(_ belief: Double) -> Int {
        switch belief {
        case ..<0.35: return 0
        case ..<0.70: return 1
        case ..<0.90: return 2
        default: return 3
        }
    }

    /// 档位中文标签。
    static func levelLabel(_ belief: Double) -> String {
        switch levelIndex(belief) {
        case 0: return "低"
        case 1: return "中"
        case 2: return "较高"
        default: return "高"
        }
    }

    /// tooltip（必须说明不确定性）。
    static func helpText(_ belief: Double) -> String {
        "模型估计掌握度 \(percentText(belief))（BKT 后验概率，随每次事件更新，不是精确测量）"
    }

    /// 无模型数据占位。
    static let noDataText = "—"

    /// 证据来源图标（SF Symbol）：显式标记 > 模型推断 > 被动 seen。
    /// @ai: 来源用图标区分，不占颜色通道（颜色只表档位）。
    static func sourceIcon(explicit: Bool, hasBelief: Bool) -> String {
        if explicit { return "hand.tap" }
        if hasBelief { return "waveform.path.ecg" }
        return "eye"
    }
}
```

**3c. `GraphQueryTypes.swift`：`CardListItem` 末尾追加字段（带默认值，既有构造点无需改动）：**

```swift
        /// BKT 后验掌握度概率；nil = 尚无事件。
        let belief: Double? = nil
```

**3d. `GraphQueries+Study.swift`：两处 SQL 与映射同步加 belief。**

`cardForLemma(_:)` 的 SELECT 追加一行：

```sql
                mb.belief       AS belief
```

`dueCards(limit:now:)` 的 SELECT 追加同一行。两处的 FROM 段各追加：

```sql
            LEFT JOIN comp_mastery_belief mb ON mb.entity_id = t.entity_id
```

两处 `CardListItem(...)` 构造追加：

```swift
                    belief: row["belief"])
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter WordMarkStateTests 2>&1 | tail -6`
Run: `swift test --filter MasteryPresentationTests 2>&1 | tail -6`
Run: `swift test --filter GraphQueriesStudyBeliefTests 2>&1 | tail -6`
Expected: 全 PASS。

- [ ] **Step 5: 回归受影响的既有测试**

Run: `swift test --filter StudySystemTests 2>&1 | tail -5`
Run: `swift test --filter GraphQueriesVocabularyTests 2>&1 | tail -5`
Run: `swift test --filter CardBrowser 2>&1 | tail -5`
Expected: 全 PASS。若既有断言是 `WordMarkState.from(mastery: 1.5, ...) == .learning(1.5)`，改为 `.learning(0.5)`（语义变更见 README 设计决定 2）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/UI/WordMarkState.swift \
        Sources/WordRecitingApp/UI/Presentation/MasteryPresentation.swift \
        Sources/WordRecitingApp/ECS/GraphQueryTypes.swift \
        Sources/WordRecitingApp/ECS/GraphQueries+Study.swift \
        Tests/WordRecitingAppTests/UI/WordMarkStateTests.swift \
        Tests/WordRecitingAppTests/UI/Presentation/MasteryPresentationTests.swift \
        Tests/WordRecitingAppTests/ECS/GraphQueriesStudyBeliefTests.swift
git commit -m "refactor(ui): WordMarkState 判定改由 BKT 概率驱动"
```

---
