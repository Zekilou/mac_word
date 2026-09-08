# Task 6：接入自动更新 + 启动全量回填

**Files:**
- Modify: `Sources/WordRecitingApp/ECS/RegionRecorder.swift`
- Modify: `Sources/WordRecitingApp/ECS/VocabularyMaintenance.swift`
- Modify: `Sources/WordRecitingApp/App/main.swift`（`makeWorld()` 两处）
- Test: `Tests/WordRecitingAppTests/ECS/RegionRecorderTests.swift`（追加）
- Test: `Tests/WordRecitingAppTests/ECS/VocabularyMaintenanceTests.swift`（追加）

**依赖：** Task 5。

**为什么放这里：** 阶段一的 6 个接入点全部经 `RegionRecorder` 写事件，所以**只改一处**就能让所有交互自动更新后验。

---

- [ ] **Step 1: 写失败测试**

**1a. 在 `Tests/WordRecitingAppTests/ECS/RegionRecorderTests.swift` 末尾追加：**

```swift
    func testRecordAlsoUpdatesBelief() throws {
        try makeLemma("L1", "abandon")
        RegionRecorder(world: world).record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .markKnown, trust: 1.0)

        let belief: MasteryBeliefComponent? = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief")
        XCTAssertNotNil(belief)
        XCTAssertEqual(belief?.opportunities, 1)
        XCTAssertGreaterThan(belief?.belief ?? 0, BKTParameters.default.fallbackPrior)
    }

    func testRecordBySurfacesAlsoUpdatesBelief() throws {
        try makeLemma("L1", "abandon")
        RegionRecorder(world: world).record(
            surfaces: ["abandon"], region: .rss(articleId: "A1", title: nil),
            kind: .seen, trust: 0)

        let belief: MasteryBeliefComponent? = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief")
        XCTAssertNotNil(belief)
    }
```

**1b. 在 `Tests/WordRecitingAppTests/ECS/VocabularyMaintenanceTests.swift` 末尾追加：**

```swift
    func testBackfillMasteryRecomputesAll() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .markKnown,
            trust: 1.0, detail: nil))

        VocabularyMaintenance.backfillMastery(world: world)

        let belief: MasteryBeliefComponent? = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief")
        XCTAssertNotNil(belief)
        XCTAssertEqual(belief?.opportunities, 1)
    }

    func testBackfillMasteryIsIdempotent() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .markKnown,
            trust: 1.0, detail: nil))

        VocabularyMaintenance.backfillMastery(world: world)
        let first = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief") as MasteryBeliefComponent?
        VocabularyMaintenance.backfillMastery(world: world)
        let second = try world.registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief") as MasteryBeliefComponent?

        XCTAssertEqual(first?.belief ?? 0, second?.belief ?? -1, accuracy: 0.0001)
        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_mastery_belief")
        }
        XCTAssertEqual(count, 1)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RegionRecorderTests 2>&1 | tail -5`
Run: `swift test --filter VocabularyMaintenanceTests 2>&1 | tail -5`
Expected: FAIL（`belief` 为 nil / `cannot find 'backfillMastery'`）。

- [ ] **Step 3: 实现**

**3a. `RegionRecorder.swift`：`record(lemmaIds:...)` 末尾追加一行重算（注意缩进层级）：**

```swift
    /// 按 lemma id 记录事件，并重算这些词的 BKT 后验。
    func record(lemmaIds: [EntityID], region: RegionRef, kind: WordEventKind,
                trust: Double? = nil, detail: String? = nil) {
        guard !lemmaIds.isEmpty else { return }
        try? world.run(RegionSystem(), context: .record(
            lemmaIds: lemmaIds, region: region, kind: kind, trust: trust, detail: detail))
        try? world.run(MasterySystem(), context: .recompute(lemmaIds: lemmaIds))
    }
```

**3b. `VocabularyMaintenance.swift`：追加：**

```swift
    /// 为全部 Lemma 重算 BKT 后验（幂等，启动时调用一次）。
    static func backfillMastery(world: World, parameters: BKTParameters = .default) {
        try? world.run(MasterySystem(parameters: parameters), context: .recomputeAll)
    }
```

**3c. `App/main.swift`：`makeWorld()` 的两处 `backfillLemmaFrequency` 之后各追加一行：**

```swift
            VocabularyMaintenance.backfillLemmaFrequency(world: world)
            VocabularyMaintenance.backfillMastery(world: world)
            return world
```

（`do` 分支与 `catch` 回退分支都要加。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RegionRecorderTests 2>&1 | tail -5`
Run: `swift test --filter VocabularyMaintenanceTests 2>&1 | tail -5`
Expected: 全 PASS。

- [ ] **Step 5: 回归接入点测试**

Run: `swift test --filter RegionWiringTests 2>&1 | tail -5`
Expected: 全 PASS（事件数不变，新增的只是 `comp_mastery_belief` 写入）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/ECS/RegionRecorder.swift \
        Sources/WordRecitingApp/ECS/VocabularyMaintenance.swift \
        Sources/WordRecitingApp/App/main.swift \
        Tests/WordRecitingAppTests/ECS/RegionRecorderTests.swift \
        Tests/WordRecitingAppTests/ECS/VocabularyMaintenanceTests.swift
git commit -m "feat(mastery): 事件写入后自动更新后验并启动全量回填"
```

---
