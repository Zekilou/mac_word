# Task 6：`FrequencyAwareIntervalPolicy` + 排期注册表

**Files:**
- Create: `Sources/WordRecitingApp/Scheduling/Strategies/FrequencyAwareIntervalPolicy.swift`
- Modify: `Sources/WordRecitingApp/Scheduling/SchedulingRegistry.swift`（加 `reviewPolicy`）
- Test: `Tests/WordRecitingAppTests/Scheduling/FrequencyAwareIntervalPolicyTests.swift`（新建）

**依赖：** Task 5。

**诚实标注：** 下面三个倍数是**启发式默认值**（不是文献常数）——高频词在语料中自然复现多，可以少复习；低频词复现少，需要更勤；模型高置信时拉长。全部集中在一处常量，便于后续调参。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/Scheduling/FrequencyAwareIntervalPolicyTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class FrequencyAwareIntervalPolicyTests: XCTestCase {
    private let policy = FrequencyAwareIntervalPolicy()

    private func features(belief: Double? = nil, band: Int? = nil) -> WordFeatures {
        WordFeatures(lemmaId: "L1", belief: belief, band: band, rank: nil,
                     eventCount: 0, contextCount: 0, lastEventAt: nil, card: nil)
    }

    private var baseState: ScheduleStateComponent {
        ScheduleStateComponent(
            entityId: "C1", stability: nil, difficulty: 2.5, dueAt: nil,
            intervalDays: 4, reps: 2, lapses: 0,
            lastRating: nil, lastReviewedAt: nil,
            schedulerId: "sm-2", queue: "review", customDataJson: nil)
    }

    private func interval(_ f: WordFeatures, _ rating: Rating = .good) -> Double {
        policy.next(state: baseState, rating: rating, features: f,
                    now: Date(timeIntervalSince1970: 1_000_000)).intervalDays ?? 0
    }

    /// SM-2 基线：4 天 × factor 2.5 = 10 天。
    private let baseline = 10.0

    func testHighFrequencyBandExtendsInterval() {
        XCTAssertEqual(interval(features(band: 1)), baseline * 1.3, accuracy: 0.0001)
        XCTAssertEqual(interval(features(band: 3)), baseline * 1.3, accuracy: 0.0001)
    }

    func testLowFrequencyBandShortensInterval() {
        XCTAssertEqual(interval(features(band: 10)), baseline * 0.8, accuracy: 0.0001)
        XCTAssertEqual(interval(features(band: 25)), baseline * 0.8, accuracy: 0.0001)
    }

    func testMidBandIsUnchanged() {
        XCTAssertEqual(interval(features(band: 5)), baseline, accuracy: 0.0001)
    }

    func testHighConfidenceExtendsInterval() {
        XCTAssertEqual(interval(features(belief: 0.95)), baseline * 1.5, accuracy: 0.0001)
    }

    func testHighConfidenceDoesNotApplyToHardRating() {
        XCTAssertEqual(interval(features(belief: 0.95), .hard), 4 * 2.35, accuracy: 0.0001)
    }

    func testMultipliersCompose() {
        // band 1（×1.3）× 高置信（×1.5）= ×1.95
        XCTAssertEqual(interval(features(belief: 0.95, band: 1)),
                       baseline * 1.95, accuracy: 0.0001)
    }

    func testNoFrequencyAndNoBeliefFallsBackToBase() {
        XCTAssertEqual(interval(features()), baseline, accuracy: 0.0001)
    }

    func testAgainIsNeverModulated() {
        let result = policy.next(state: baseState, rating: .again,
                                 features: features(belief: 0.99, band: 1),
                                 now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(result.intervalDays ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(result.lapses, 1)
    }

    func testSchedulerIdIsWritten() {
        let result = policy.next(state: baseState, rating: .good,
                                 features: features(band: 1),
                                 now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(result.schedulerId, "sm-2-frequency")
    }

    // MARK: - 注册表

    func testReviewRegistryCoversAllIDs() {
        for id in SchedulerID.allCases {
            XCTAssertEqual(SchedulingRegistry.reviewPolicy(id).id, id)
        }
    }
}
```

> `SchedulerID.allCases` 含 `.fsrsV4`；本 Task 注册表先把它映射到 `SM2IntervalPolicy`（FSRS 未实现前的安全兜底，Task 6 Step 3 里注明）。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter FrequencyAwareIntervalPolicyTests 2>&1 | tail -8`
Expected: FAIL（`cannot find 'FrequencyAwareIntervalPolicy' in scope`）。

- [ ] **Step 3: 实现**

**3a. 新建 `Sources/WordRecitingApp/Scheduling/Strategies/FrequencyAwareIntervalPolicy.swift`：**

```swift
import Foundation

/// SM-2 + 词频/概率调制。
/// @ai: 三个倍数是**启发式默认值**（非文献常数），集中在此便于调参：
///      高频词（band ≤ 3）在语料中自然复现多 → 拉长 30%；
///      低频词（band ≥ 10）复现少 → 缩短 20%；
///      模型高置信（belief ≥ 0.9）且非 again/hard → 额外拉长 50%。
///      `again` 不调制（重置到 1 天是刻意的）。
struct FrequencyAwareIntervalPolicy: ReviewIntervalPolicy {
    let id: SchedulerID = .sm2Frequency

    /// 高频带上界（含）。
    static let highFrequencyMaxBand = 3
    /// 低频带下界（含）。
    static let lowFrequencyMinBand = 10
    static let highFrequencyMultiplier = 1.3
    static let lowFrequencyMultiplier = 0.8
    static let highConfidenceMultiplier = 1.5
    static let highConfidenceThreshold = 0.9

    private let base = SM2IntervalPolicy()

    func next(state: ScheduleStateComponent, rating: Rating,
              features: WordFeatures, now: Date) -> ScheduleStateComponent {
        let baseResult = base.next(state: state, rating: rating,
                                   features: features, now: now)
        guard rating != .again else { return stamped(baseResult) }

        var multiplier = 1.0
        if let band = features.band, band >= 1 {
            if band <= Self.highFrequencyMaxBand {
                multiplier *= Self.highFrequencyMultiplier
            } else if band >= Self.lowFrequencyMinBand {
                multiplier *= Self.lowFrequencyMultiplier
            }
        }
        if let belief = features.belief,
           belief >= Self.highConfidenceThreshold,
           rating.rawValue >= Rating.good.rawValue {
            multiplier *= Self.highConfidenceMultiplier
        }
        guard multiplier != 1.0 else { return stamped(baseResult) }

        let interval = (baseResult.intervalDays ?? 0) * multiplier
        return ScheduleStateComponent(
            entityId: baseResult.entityId,
            stability: interval,
            difficulty: baseResult.difficulty,
            dueAt: now.addingTimeInterval(interval * 86400),
            intervalDays: interval,
            reps: baseResult.reps,
            lapses: baseResult.lapses,
            lastRating: baseResult.lastRating,
            lastReviewedAt: baseResult.lastReviewedAt,
            schedulerId: id.rawValue,
            queue: interval < 1 ? "learning" : "review",
            customDataJson: nil)
    }

    /// 把 schedulerId 标成本策略（未调制时也要标，便于回放归因）。
    private func stamped(_ state: ScheduleStateComponent) -> ScheduleStateComponent {
        var copy = state
        copy.schedulerId = id.rawValue
        return copy
    }
}
```

**3b. `SchedulingRegistry.swift` 追加：**

```swift
    static func reviewPolicy(_ id: SchedulerID) -> any ReviewIntervalPolicy {
        switch id {
        case .sm2: return SM2IntervalPolicy()
        case .sm2Frequency: return FrequencyAwareIntervalPolicy()
        // FSRS 未实现：先回退 SM-2，避免设置成 fsrs 后无策略可用。
        case .fsrsV4: return SM2IntervalPolicy()
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter FrequencyAwareIntervalPolicyTests 2>&1 | tail -8`
Run: `swift test --filter SM2IntervalPolicyTests 2>&1 | tail -5`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/Scheduling/Strategies/FrequencyAwareIntervalPolicy.swift \
        Sources/WordRecitingApp/Scheduling/SchedulingRegistry.swift \
        Tests/WordRecitingAppTests/Scheduling/FrequencyAwareIntervalPolicyTests.swift
git commit -m "feat(scheduling): 词频/概率调制的排期策略与注册表"
```

---
