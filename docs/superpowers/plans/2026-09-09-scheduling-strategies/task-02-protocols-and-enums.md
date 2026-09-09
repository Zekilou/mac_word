# Task 2：协议 + 枚举 + `WordSelector`

**Files:**
- Modify: `Sources/WordRecitingApp/AppTypes.swift`（`SchedulerID` 追加 case；新增 `WordScoringID`）
- Create: `Sources/WordRecitingApp/Scheduling/SchedulingStrategy.swift`
- Create: `Sources/WordRecitingApp/Scheduling/WordSelector.swift`
- Test: `Tests/WordRecitingAppTests/Scheduling/SchedulingStrategyTests.swift`（新建）

**依赖：** Task 1。

**目标：** 定死两个协议与两个枚举的边界；`WordSelector` 提供「按分数取词」的纯函数（top-N / 阈值）。

> 注册表 `SchedulingRegistry` 不在本 Task 建——它要等策略实现齐了才能编译（选词在 Task 3、排期在 Task 6）。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/Scheduling/SchedulingStrategyTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

/// 最小可用的打分策略：按固定表打分，用于验证 WordSelector 的取词逻辑。
private struct StubScoring: WordScoringStrategy {
    let id: WordScoringID = .random
    let table: [EntityID: Double]
    func score(_ f: WordFeatures, context: ScoringContext) -> Double {
        table[f.lemmaId] ?? 0
    }
}

final class SchedulingStrategyTests: XCTestCase {

    // MARK: - 枚举（合同文件只追加）

    func testSchedulerIDKeepsExistingRawValues() {
        XCTAssertEqual(SchedulerID.sm2.rawValue, "sm-2")
        XCTAssertEqual(SchedulerID.fsrsV4.rawValue, "fsrs-v4")
        XCTAssertEqual(SchedulerID.sm2Frequency.rawValue, "sm-2-frequency")
        XCTAssertEqual(SchedulerID.allCases.last, .sm2Frequency, "新 case 只能追加到末尾")
    }

    func testWordScoringIDRawValues() {
        XCTAssertEqual(WordScoringID.random.rawValue, "random")
        XCTAssertEqual(WordScoringID.criticalWords.rawValue, "critical-words")
        XCTAssertEqual(WordScoringID.frequencyTier.rawValue, "frequency-tier")
        XCTAssertEqual(WordScoringID.allCases.count, 3)
    }

    // MARK: - WordSelector

    private func features(_ ids: [EntityID]) -> [WordFeatures] {
        ids.map { id in
            WordFeatures(lemmaId: id, belief: nil, band: nil, rank: nil,
                         eventCount: 0, contextCount: 0, lastEventAt: nil, card: nil)
        }
    }

    private let context = ScoringContext(purpose: .articleTargets,
                                         now: Date(), bandWindow: nil)

    func testTopNPicksHighestScores() {
        let strategy = StubScoring(table: ["L1": 0.1, "L2": 0.9, "L3": 0.5])
        let picked = WordSelector.top(2, from: features(["L1", "L2", "L3"]),
                                      strategy: strategy, context: context)
        XCTAssertEqual(picked, ["L2", "L3"])
    }

    func testTopNCapsAtAvailableCount() {
        let strategy = StubScoring(table: ["L1": 0.1])
        XCTAssertEqual(WordSelector.top(5, from: features(["L1"]),
                                        strategy: strategy, context: context), ["L1"])
    }

    func testTopNZeroOrEmptyReturnsEmpty() {
        let strategy = StubScoring(table: ["L1": 0.1])
        XCTAssertTrue(WordSelector.top(0, from: features(["L1"]),
                                       strategy: strategy, context: context).isEmpty)
        XCTAssertTrue(WordSelector.top(3, from: [],
                                       strategy: strategy, context: context).isEmpty)
    }

    func testThresholdPicksAboveAndSortsDescending() {
        let strategy = StubScoring(table: ["L1": 0.2, "L2": 0.8, "L3": 0.6])
        let picked = WordSelector.above(0.5, from: features(["L1", "L2", "L3"]),
                                        strategy: strategy, context: context)
        XCTAssertEqual(picked, ["L2", "L3"])
    }

    func testTiesAreStableByLemmaId() {
        let strategy = StubScoring(table: ["L1": 0.5, "L2": 0.5, "L3": 0.5])
        XCTAssertEqual(WordSelector.top(2, from: features(["L1", "L2", "L3"]),
                                        strategy: strategy, context: context), ["L1", "L2"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SchedulingStrategyTests 2>&1 | tail -8`
Expected: FAIL（`cannot find 'WordScoringStrategy' in scope`）。

- [ ] **Step 3: 实现**

**3a. `AppTypes.swift`：`SchedulerID` 末尾追加 case**（在 `case sm2 = "sm-2"` 之后）：

```swift
    /// SM-2 + 词频/概率调制。
    case sm2Frequency = "sm-2-frequency"
```

**3b. 同文件末尾追加新枚举：**

```swift
/// 选词打分策略。
enum WordScoringID: String, Sendable, Codable, CaseIterable {
    /// 纯随机（复刻旧行为）。
    case random
    /// 临界词优先：概率 0.5 附近最该练。
    case criticalWords = "critical-words"
    /// 词频分层：按词频带优先。
    case frequencyTier = "frequency-tier"
}
```

**3c. 新建 `Sources/WordRecitingApp/Scheduling/SchedulingStrategy.swift`：**

```swift
import Foundation

/// 打分上下文：策略据此区分用途。
struct ScoringContext: Sendable, Equatable {
    enum Purpose: String, Sendable {
        /// 造文选目标词。
        case articleTargets
        /// 阅读高亮。
        case readingHighlight
        /// 初始化段落。
        case initParagraph
    }

    let purpose: Purpose
    let now: Date
    /// 期望词频带窗口（nil = 不限）。
    let bandWindow: ClosedRange<Int>?
}

/// 选词打分策略：分数越高越优先。
/// @ai: 确定性纯函数，不碰数据库；取词方式（top-N / 阈值）由调用方决定。
protocol WordScoringStrategy: Sendable {
    var id: WordScoringID { get }
    func score(_ f: WordFeatures, context: ScoringContext) -> Double
}

/// 复习排期策略：算下一次调度状态。
/// @ai: 纯函数，不改 DB——由调用方（StudySystem）写回。
protocol ReviewIntervalPolicy: Sendable {
    var id: SchedulerID { get }
    func next(state: ScheduleStateComponent, rating: Rating,
              features: WordFeatures, now: Date) -> ScheduleStateComponent
}
```

**3d. 新建 `Sources/WordRecitingApp/Scheduling/WordSelector.swift`：**

```swift
import Foundation

/// 按策略打分取词（纯函数）。
/// @ai: 同分时按 lemmaId 升序稳定排序，保证结果可复现。
enum WordSelector {

    /// 取分数最高的前 n 个。
    static func top(_ n: Int, from features: [WordFeatures],
                    strategy: any WordScoringStrategy,
                    context: ScoringContext) -> [EntityID] {
        guard n > 0, !features.isEmpty else { return [] }
        return ranked(features, strategy: strategy, context: context)
            .prefix(n)
            .map(\.lemmaId)
    }

    /// 取分数 ≥ threshold 的全部（按分数降序）。
    static func above(_ threshold: Double, from features: [WordFeatures],
                      strategy: any WordScoringStrategy,
                      context: ScoringContext) -> [EntityID] {
        ranked(features, strategy: strategy, context: context)
            .filter { $0.score >= threshold }
            .map(\.lemmaId)
    }

    private static func ranked(_ features: [WordFeatures],
                               strategy: any WordScoringStrategy,
                               context: ScoringContext) -> [(lemmaId: EntityID, score: Double)] {
        features
            .map { (lemmaId: $0.lemmaId, score: strategy.score($0, context: context)) }
            .sorted {
                $0.score == $1.score ? $0.lemmaId < $1.lemmaId : $0.score > $1.score
            }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SchedulingStrategyTests 2>&1 | tail -8`
Expected: 7 tests PASS。

- [ ] **Step 5: 回归合同枚举测试**

Run: `swift test --filter AppTypesTests 2>&1 | tail -5`
Run: `swift test --filter RegionTypesTests 2>&1 | tail -5`
Expected: 全 PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/AppTypes.swift \
        Sources/WordRecitingApp/Scheduling/SchedulingStrategy.swift \
        Sources/WordRecitingApp/Scheduling/WordSelector.swift \
        Tests/WordRecitingAppTests/Scheduling/SchedulingStrategyTests.swift
git commit -m "feat(scheduling): 打分/排期协议、策略枚举与取词器"
```

---
