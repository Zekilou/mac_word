# Task 5：`SM2IntervalPolicy`（逐字复刻现有公式）

**Files:**
- Create: `Sources/WordRecitingApp/Scheduling/Strategies/SM2IntervalPolicy.swift`
- Test: `Tests/WordRecitingAppTests/Scheduling/SM2IntervalPolicyTests.swift`（新建）

**依赖：** Task 2。

**关键：** 公式**逐字复刻** `StudySystem.swift` L37–64，保证默认策略下复习手感与升级前完全一致。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/Scheduling/SM2IntervalPolicyTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class SM2IntervalPolicyTests: XCTestCase {
    private let policy = SM2IntervalPolicy()

    private func features() -> WordFeatures {
        WordFeatures(lemmaId: "L1", belief: nil, band: nil, rank: nil,
                     eventCount: 0, contextCount: 0, lastEventAt: nil, card: nil)
    }

    private func state(reps: Int?, difficulty: Double?,
                       intervalDays: Double?) -> ScheduleStateComponent {
        ScheduleStateComponent(
            entityId: "C1", stability: nil, difficulty: difficulty, dueAt: nil,
            intervalDays: intervalDays, reps: reps, lapses: 0,
            lastRating: nil, lastReviewedAt: nil,
            schedulerId: "sm-2", queue: "new", customDataJson: nil)
    }

    private func next(_ s: ScheduleStateComponent, _ rating: Rating,
                      now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ScheduleStateComponent {
        policy.next(state: s, rating: rating, features: features(), now: now)
    }

    // MARK: - 首次复习

    func testFirstReviewIntervals() {
        let fresh = state(reps: nil, difficulty: nil, intervalDays: nil)
        XCTAssertEqual(next(fresh, .again).intervalDays ?? 0, 10.0 / 1440.0, accuracy: 0.000001)
        XCTAssertEqual(next(fresh, .hard).intervalDays ?? 0, 1, accuracy: 0.000001)
        XCTAssertEqual(next(fresh, .good).intervalDays ?? 0, 3, accuracy: 0.000001)
        XCTAssertEqual(next(fresh, .easy).intervalDays ?? 0, 7, accuracy: 0.000001)
    }

    // MARK: - 后续复习

    func testAgainResetsIntervalAndDropsFactor() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 10), .again)
        XCTAssertEqual(result.intervalDays ?? 0, 1, accuracy: 0.000001)
        XCTAssertEqual(result.lapses, 1)
        XCTAssertEqual(result.difficulty ?? 0, 2.3, accuracy: 0.0001)
    }

    func testFactorFloorIsOnePointThree() {
        let result = next(state(reps: 5, difficulty: 1.35, intervalDays: 5), .again)
        XCTAssertEqual(result.difficulty ?? 0, 1.3, accuracy: 0.0001)
    }

    func testGoodMultipliesByFactor() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .good)
        XCTAssertEqual(result.intervalDays ?? 0, 10, accuracy: 0.0001)
    }

    func testHardUsesReducedFactor() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .hard)
        XCTAssertEqual(result.intervalDays ?? 0, 4 * 2.35, accuracy: 0.0001)
    }

    func testEasyAddsThirtyPercent() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .easy)
        XCTAssertEqual(result.intervalDays ?? 0, 4 * 2.5 * 1.3, accuracy: 0.0001)
    }

    // MARK: - 元数据

    func testQueueFollowsInterval() {
        XCTAssertEqual(next(state(reps: nil, difficulty: nil, intervalDays: nil), .again).queue,
                       "learning")
        XCTAssertEqual(next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .good).queue,
                       "review")
    }

    func testSchedulerIdAndDueAt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .good, now: now)
        XCTAssertEqual(result.schedulerId, "sm-2")
        XCTAssertEqual(result.dueAt ?? .distantPast, now.addingTimeInterval(10 * 86400))
    }

    func testRepsAndLastRatingAreUpdated() {
        let result = next(state(reps: 2, difficulty: 2.5, intervalDays: 4), .good)
        XCTAssertEqual(result.reps, 3)
        XCTAssertEqual(result.lastRating, Rating.good.rawValue)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SM2IntervalPolicyTests 2>&1 | tail -8`
Expected: FAIL（`cannot find 'SM2IntervalPolicy' in scope`）。

- [ ] **Step 3: 实现**

新建 `Sources/WordRecitingApp/Scheduling/Strategies/SM2IntervalPolicy.swift`：

```swift
import Foundation

/// 简化版 SM-2 排期策略（**逐字复刻** StudySystem 原有公式，保证默认手感不变）。
/// @ai: `stability` 存的是间隔天数、`difficulty` 存的是 SM-2 的 factor（历史字段名沿用）。
struct SM2IntervalPolicy: ReviewIntervalPolicy {
    let id: SchedulerID = .sm2

    func next(state: ScheduleStateComponent, rating: Rating,
              features: WordFeatures, now: Date) -> ScheduleStateComponent {
        let reps = (state.reps ?? 0) + 1
        var lapses = state.lapses ?? 0
        var factor = state.difficulty ?? 2.5
        var interval: Double
        let previousInterval = state.intervalDays ?? 0

        if reps == 1 {
            switch rating {
            case .again: interval = 10.0 / 1440.0
            case .hard: interval = 1
            case .good: interval = 3
            case .easy: interval = 7
            }
        } else {
            switch rating {
            case .again:
                interval = 1
                lapses += 1
                factor = max(1.3, factor - 0.2)
            case .hard:
                interval = previousInterval * max(1.3, factor - 0.15)
            case .good:
                interval = previousInterval * factor
            case .easy:
                interval = previousInterval * factor * 1.3
            }
        }

        return ScheduleStateComponent(
            entityId: state.entityId,
            stability: interval,
            difficulty: factor,
            dueAt: now.addingTimeInterval(interval * 86400),
            intervalDays: interval,
            reps: reps,
            lapses: lapses,
            lastRating: rating.rawValue,
            lastReviewedAt: now,
            schedulerId: id.rawValue,
            queue: interval < 1 ? "learning" : "review",
            customDataJson: nil)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SM2IntervalPolicyTests 2>&1 | tail -8`
Expected: 8 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/Scheduling/Strategies/SM2IntervalPolicy.swift \
        Tests/WordRecitingAppTests/Scheduling/SM2IntervalPolicyTests.swift
git commit -m "feat(scheduling): SM2IntervalPolicy 抽离并逐字复刻现有公式"
```

---
