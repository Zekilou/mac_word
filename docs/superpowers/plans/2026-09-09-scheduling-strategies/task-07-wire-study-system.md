# Task 7：`StudySystem` 接入排期策略 + 设置页

**Files:**
- Modify: `Sources/WordRecitingApp/ECS/GraphQueries+Features.swift`（加 `lemmaIdForCard`）
- Modify: `Sources/WordRecitingApp/ECS/Systems/StudySystem.swift`（调 `ReviewIntervalPolicy`）
- Modify: `Sources/WordRecitingApp/UI/StudyViewModel.swift`（传 `policyID`）
- Modify: `Sources/WordRecitingApp/Settings/GeneralSettingsView.swift`（新策略文案）
- Test: `Tests/WordRecitingAppTests/ECS/Systems/StudyPolicyTests.swift`（新建）

**依赖：** Task 5、Task 6。

**默认行为不变**：`StudyOp.policyID` 默认 `.sm2`，既有调用点无需改动。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/Systems/StudyPolicyTests.swift`：

```swift
import XCTest
import GRDB
@testable import WordRecitingApp

@MainActor
final class StudyPolicyTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeCard(lemmaId: String, cardId: String, band: Int?) throws {
        let now = Date()
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: now)
        try world.registry.insertNode(id: cardId, kind: .card, createdAt: now)
        try world.registry.insertEdge(id: "edge-\(cardId)", srcId: cardId, dstId: lemmaId,
                                      rel: .instantiates, createdAt: now)
        if let band {
            try world.registry.upsertComponent(LemmaFrequencyComponent(
                entityId: lemmaId, band: band, freqRank: band * 1000, source: "test"))
        }
    }

    private func state(_ cardId: String) throws -> ScheduleStateComponent? {
        try world.registry.fetchComponents(for: cardId, table: "comp_schedule_state")
    }

    func testDefaultPolicyIsSM2() throws {
        try makeCard(lemmaId: "L1", cardId: "C1", band: nil)

        try world.run(StudySystem(), context: StudySystem.StudyOp(
            cardId: "C1", rating: .good, reviewedAt: Date()))

        XCTAssertEqual(try state("C1")?.intervalDays ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(try state("C1")?.schedulerId, "sm-2")
    }

    func testFrequencyPolicyExtendsHighFrequencyWord() throws {
        try makeCard(lemmaId: "L1", cardId: "C1", band: 1)

        try world.run(StudySystem(), context: StudySystem.StudyOp(
            cardId: "C1", rating: .good, reviewedAt: Date(), policyID: .sm2Frequency))

        XCTAssertEqual(try state("C1")?.intervalDays ?? 0, 3 * 1.3, accuracy: 0.0001)
        XCTAssertEqual(try state("C1")?.schedulerId, "sm-2-frequency")
    }

    func testFrequencyPolicyShortsLowFrequencyWord() throws {
        try makeCard(lemmaId: "L1", cardId: "C1", band: 25)

        try world.run(StudySystem(), context: StudySystem.StudyOp(
            cardId: "C1", rating: .good, reviewedAt: Date(), policyID: .sm2Frequency))

        XCTAssertEqual(try state("C1")?.intervalDays ?? 0, 3 * 0.8, accuracy: 0.0001)
    }

    func testWritesReviewEvent() throws {
        try makeCard(lemmaId: "L1", cardId: "C1", band: nil)

        try world.run(StudySystem(), context: StudySystem.StudyOp(
            cardId: "C1", rating: .good, reviewedAt: Date()))

        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_review_event")
        }
        XCTAssertEqual(count, 1)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter StudyPolicyTests 2>&1 | tail -8`
Expected: FAIL（`extra argument 'policyID' in call`）。

- [ ] **Step 3: 实现**

**3a. `GraphQueries+Features.swift` 追加：**

```swift
    /// db 版本：卡片对应的词元（instantiates 边）。
    func lemmaIdForCard(_ db: Database, cardId: EntityID) throws -> EntityID? {
        try String.fetchOne(db, sql: """
            SELECT dst_id FROM edges
            WHERE src_id = ? AND rel_type = 'instantiates'
            LIMIT 1
            """, arguments: [cardId])
    }
```

**3b. `StudySystem.swift`：**

- `StudyOp` 追加字段（带默认值，既有调用点不受影响）：

```swift
    struct StudyOp: Sendable {
        let cardId: EntityID
        let rating: Rating
        let reviewedAt: Date
        /// 排期策略（由 StudyViewModel 从设置读入——System 不碰 UI/设置）。
        var policyID: SchedulerID = .sm2
    }
```

- `execute` 中「计算新调度参数」与「更新 schedule_state」两段（原 L30–80）整体替换为：

```swift
        let now = context.reviewedAt
        let existing: ScheduleStateComponent? = try world.registry.fetchComponents(
            db, for: context.cardId, table: "comp_schedule_state")
        let old = existing ?? ScheduleStateComponent(
            entityId: context.cardId, stability: nil, difficulty: nil,
            dueAt: nil, intervalDays: nil, reps: 0, lapses: 0,
            lastRating: nil, lastReviewedAt: nil, schedulerId: "sm-2",
            queue: "new", customDataJson: nil)

        let lemmaId = try world.graph.lemmaIdForCard(db, cardId: context.cardId)
        let features: WordFeatures
        if let lemmaId,
           let found = try world.graph.wordFeatures(db, lemmaIds: [lemmaId])[lemmaId] {
            features = found
        } else {
            features = WordFeatures(lemmaId: lemmaId ?? context.cardId, belief: nil,
                                    band: nil, rank: nil, eventCount: 0,
                                    contextCount: 0, lastEventAt: nil, card: nil)
        }

        let policy = SchedulingRegistry.reviewPolicy(context.policyID)
        let newState = policy.next(state: old, rating: context.rating,
                                   features: features, now: now)
        try world.registry.upsertComponent(db, newState)

        let interval = newState.intervalDays ?? 0
        let previousInterval = old.intervalDays ?? 0
```

- `ReviewEventComponent` 的构造改为从 `newState` 取（保持字段语义）：

```swift
        try world.registry.upsertComponent(db, ReviewEventComponent(
            entityId: eventId,
            targetCardId: context.cardId,
            ratedAt: now,
            rating: context.rating.rawValue,
            respondedMs: nil,
            elapsedDays: previousInterval,
            scheduledInterval: interval,
            deltaStability: interval - previousInterval,
            deltaDifficulty: (newState.difficulty ?? 2.5) - (old.difficulty ?? 2.5),
            lastIvl: previousInterval,
            factor: newState.difficulty ?? 2.5))
```

**3c. `StudyViewModel.swift` 的 `rate(_:)`：**

```swift
    func rate(_ rating: Rating) {
        guard let card = currentCard else { return }
        do {
            try world.run(StudySystem(), context: StudySystem.StudyOp(
                cardId: card.cardId, rating: rating, reviewedAt: Date(),
                policyID: settings.schedulerID))
            ...
```

> `StudyViewModel` 需要持有 `settings`：init 增加 `settings: AppSettings = .shared` 并存为属性；`StudyView` 的调用不用改（默认值）。

**3d. `GeneralSettingsView.swift` 的 `label(for:)` 追加：**

```swift
        case .sm2Frequency: return "SM-2 + 词频调制"
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter StudyPolicyTests 2>&1 | tail -8`
Run: `swift test --filter StudyViewModelTests 2>&1 | tail -5`
Expected: 全 PASS。

- [ ] **Step 5: 回归复习相关**

Run: `swift test --filter StudySystem 2>&1 | tail -5`
Run: `swift test --filter GraphQueriesStudy 2>&1 | tail -5`
Expected: 全 PASS（默认 `.sm2` 行为与升级前一致）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/ECS/GraphQueries+Features.swift \
        Sources/WordRecitingApp/ECS/Systems/StudySystem.swift \
        Sources/WordRecitingApp/UI/StudyViewModel.swift \
        Sources/WordRecitingApp/Settings/GeneralSettingsView.swift \
        Tests/WordRecitingAppTests/ECS/Systems/StudyPolicyTests.swift
git commit -m "feat(study): 复习排期接入可插拔策略"
```

---
