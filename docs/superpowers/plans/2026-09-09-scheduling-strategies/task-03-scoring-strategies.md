# Task 3：三个选词策略 + `SchedulingRegistry.scoring`

**Files:**
- Create: `Sources/WordRecitingApp/Scheduling/Strategies/RandomScoring.swift`
- Create: `Sources/WordRecitingApp/Scheduling/Strategies/CriticalWordScoring.swift`
- Create: `Sources/WordRecitingApp/Scheduling/Strategies/FrequencyTierScoring.swift`
- Create: `Sources/WordRecitingApp/Scheduling/SchedulingRegistry.swift`
- Test: `Tests/WordRecitingAppTests/Scheduling/ScoringStrategiesTests.swift`（新建）

**依赖：** Task 2。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/Scheduling/ScoringStrategiesTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class ScoringStrategiesTests: XCTestCase {

    private func features(_ id: EntityID, belief: Double? = nil, band: Int? = nil) -> WordFeatures {
        WordFeatures(lemmaId: id, belief: belief, band: band, rank: nil,
                     eventCount: 0, contextCount: 0, lastEventAt: nil, card: nil)
    }

    private func context(bandWindow: ClosedRange<Int>? = nil) -> ScoringContext {
        ScoringContext(purpose: .articleTargets, now: Date(), bandWindow: bandWindow)
    }

    // MARK: - RandomScoring

    func testRandomScoringStaysInUnitRange() {
        let strategy = RandomScoring()
        for _ in 0..<50 {
            let value = strategy.score(features("L1"), context: context())
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    // MARK: - CriticalWordScoring

    func testCriticalScoringPeaksAtHalf() {
        let strategy = CriticalWordScoring()
        XCTAssertEqual(strategy.score(features("L1", belief: 0.5), context: context()),
                       1.0, accuracy: 0.0001)
    }

    func testCriticalScoringFallsOffAtExtremes() {
        let strategy = CriticalWordScoring()
        XCTAssertEqual(strategy.score(features("L1", belief: 0.0), context: context()),
                       0.0, accuracy: 0.0001)
        XCTAssertEqual(strategy.score(features("L1", belief: 1.0), context: context()),
                       0.0, accuracy: 0.0001)
        XCTAssertEqual(strategy.score(features("L1", belief: 0.25), context: context()),
                       0.5, accuracy: 0.0001)
    }

    func testCriticalScoringWithoutBeliefIsNeutral() {
        let strategy = CriticalWordScoring()
        XCTAssertEqual(strategy.score(features("L1", belief: nil), context: context()),
                       0.5, accuracy: 0.0001)
    }

    // MARK: - FrequencyTierScoring

    func testFrequencyTierPrefersHighFrequencyBands() {
        let strategy = FrequencyTierScoring()
        XCTAssertEqual(strategy.score(features("L1", band: 1), context: context()),
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(strategy.score(features("L1", band: 25), context: context()),
                       0.0, accuracy: 0.0001)
        XCTAssertEqual(strategy.score(features("L1", band: 3), context: context()),
                       1.0 - 2.0 / 24.0, accuracy: 0.0001)
    }

    func testFrequencyTierRespectsBandWindow() {
        let strategy = FrequencyTierScoring()
        let window = context(bandWindow: 1...3)
        XCTAssertGreaterThan(strategy.score(features("L1", band: 3), context: window), 0)
        XCTAssertEqual(strategy.score(features("L1", band: 5), context: window), 0,
                       "窗口外直接 0")
    }

    func testFrequencyTierWithoutBandIsZero() {
        let strategy = FrequencyTierScoring()
        XCTAssertEqual(strategy.score(features("L1", band: nil), context: context()), 0)
    }

    // MARK: - 注册表

    func testScoringRegistryCoversAllIDs() {
        for id in WordScoringID.allCases {
            XCTAssertEqual(SchedulingRegistry.scoring(id).id, id)
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ScoringStrategiesTests 2>&1 | tail -8`
Expected: FAIL（`cannot find 'RandomScoring' in scope`）。

- [ ] **Step 3: 实现**

**3a. 新建 `Sources/WordRecitingApp/Scheduling/Strategies/RandomScoring.swift`：**

```swift
import Foundation

/// 纯随机打分（复刻旧 randomPick 行为）。
struct RandomScoring: WordScoringStrategy {
    let id: WordScoringID = .random

    func score(_ f: WordFeatures, context: ScoringContext) -> Double {
        Double.random(in: 0...1)
    }
}
```

**3b. 新建 `Sources/WordRecitingApp/Scheduling/Strategies/CriticalWordScoring.swift`：**

```swift
import Foundation

/// 临界词优先：概率越接近 0.5（会不会的边缘）越该练。
/// @ai: 动机——两端（0.05 / 0.95）练它边际收益最低；无概率时给中性 0.5。
struct CriticalWordScoring: WordScoringStrategy {
    let id: WordScoringID = .criticalWords

    func score(_ f: WordFeatures, context: ScoringContext) -> Double {
        guard let belief = f.belief else { return 0.5 }
        return 1 - abs(belief - 0.5) / 0.5
    }
}
```

**3c. 新建 `Sources/WordRecitingApp/Scheduling/Strategies/FrequencyTierScoring.swift`：**

```swift
import Foundation

/// 词频分层：词频带越小（越高频）越优先；带窗口外直接 0。
/// @ai: 无词频坐标（band == nil）给 0，排在最后——宁可不用它，也不猜。
struct FrequencyTierScoring: WordScoringStrategy {
    let id: WordScoringID = .frequencyTier

    func score(_ f: WordFeatures, context: ScoringContext) -> Double {
        guard let band = f.band, band >= 1 else { return 0 }
        if let window = context.bandWindow, !window.contains(band) { return 0 }
        return 1 - Double(band - 1) / 24.0
    }
}
```

**3d. 新建 `Sources/WordRecitingApp/Scheduling/SchedulingRegistry.swift`：**

```swift
import Foundation

/// 策略注册表：id → 实现。
/// @ai: 每个枚举 case 都必须有实现，`ScoringStrategiesTests` 会遍历 allCases 校验。
enum SchedulingRegistry {

    static func scoring(_ id: WordScoringID) -> any WordScoringStrategy {
        switch id {
        case .random: return RandomScoring()
        case .criticalWords: return CriticalWordScoring()
        case .frequencyTier: return FrequencyTierScoring()
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ScoringStrategiesTests 2>&1 | tail -8`
Expected: 9 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/Scheduling/Strategies/RandomScoring.swift \
        Sources/WordRecitingApp/Scheduling/Strategies/CriticalWordScoring.swift \
        Sources/WordRecitingApp/Scheduling/Strategies/FrequencyTierScoring.swift \
        Sources/WordRecitingApp/Scheduling/SchedulingRegistry.swift \
        Tests/WordRecitingAppTests/Scheduling/ScoringStrategiesTests.swift
git commit -m "feat(scheduling): 随机/临界词/词频分层三个选词策略"
```

---
