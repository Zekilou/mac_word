# Task 2：词表页改造

**Files:**
- Modify: `Sources/WordRecitingApp/ECS/GraphQueries+Vocabulary.swift`（`RecordedLemma` 加上下文多样性 / 事件数）
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyListViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyListView.swift`
- Test: `Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift`（追加）

**依赖：** Task 1。

**审计对照（README 表格第 2 行）：** 现状是「状态圆点 + 状态标签 + `mastery 0.0~2.0` 裸数值 + 阅读频次 N 次」。改法：去掉裸 mastery 数值 → 概率百分比；判定走概率；「阅读频次」→「上下文多样性 + 事件数」；排序加「掌握度高→低」。

---

- [ ] **Step 1: 写失败测试**

在 `Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift` 末尾追加：

```swift
    // MARK: - 概率主口径改造

    private func seedEntry(lemmaId: String, text: String, mastery: Double?,
                           belief: Double?, seenCount: Int = 1) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: lemmaId, textA: text, textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: lemmaId, mastery: mastery ?? 0, seenCount: seenCount,
            source: "init", updatedAt: Date()))
        if let belief {
            try world.registry.upsertComponent(MasteryBeliefComponent(
                entityId: lemmaId, belief: belief, opportunities: 3,
                lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        }
    }

    /// 用户标了「会」，但模型概率低 → 判定以概率为准。
    func testStateIsDrivenByBeliefNotMastery() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: 0.12)

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)

        XCTAssertEqual(vm.markState(entry), .unknown)
    }

    func testStateFallsBackToMasteryWithoutBelief() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: nil)

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)

        XCTAssertEqual(vm.markState(entry), .known)
    }

    func testContextAndEventCountsAreLoaded() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: 0.8)
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .lookup, trust: 1.0, detail: nil))
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .rss(articleId: "A1", title: nil),
            kind: .seen, trust: 0.0, detail: nil))

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)

        XCTAssertEqual(entry.contextCount, 2)
        XCTAssertEqual(entry.eventCount, 2)
    }

    func testSortByMasteryDescending() throws {
        try seedEntry(lemmaId: "L1", text: "low", mastery: 2.0, belief: 0.2)
        try seedEntry(lemmaId: "L2", text: "high", mastery: 2.0, belief: 0.9)
        try seedEntry(lemmaId: "L3", text: "none", mastery: 2.0, belief: nil)

        let vm = VocabularyListViewModel(world: world)
        vm.sortOrder = .mastery

        XCTAssertEqual(vm.filtered.map(\.lemmaID), ["L2", "L1", "L3"])
    }

    func testBeliefTextUsesPercentPresentation() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: 0.847)

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)

        XCTAssertEqual(vm.beliefText(entry), "85%")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter VocabularyListViewModelTests 2>&1 | tail -8`
Expected: FAIL（`value of type 'GraphQueries.RecordedLemma' has no member 'contextCount'` / `no member 'markState'`）。

- [ ] **Step 3: 实现**

**3a. `GraphQueries+Vocabulary.swift`：`RecordedLemma` 末尾追加两个字段（带默认值，既有构造点兼容）：**

```swift
        /// 上下文多样性：出现过的不同 region 数。
        let contextCount: Int = 0
        /// 词事件总数。
        let eventCount: Int = 0
```

`recordedLemmas()` 整体替换为：

```swift
    func recordedLemmas() throws -> [RecordedLemma] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT k.entity_id, t.text_a AS text, t.text_b AS definition,
                       k.mastery, k.seen_count, k.source, k.updated_at,
                       b.belief AS belief,
                       (SELECT COUNT(DISTINCT e.region_id) FROM comp_word_event e
                        WHERE e.lemma_id = k.entity_id) AS context_count,
                       (SELECT COUNT(*) FROM comp_word_event e
                        WHERE e.lemma_id = k.entity_id) AS event_count
                FROM comp_user_known k
                LEFT JOIN comp_text t ON t.entity_id = k.entity_id
                LEFT JOIN comp_mastery_belief b ON b.entity_id = k.entity_id
                WHERE k.mastery > 0 OR k.seen_count > 0
                ORDER BY k.updated_at DESC, k.entity_id DESC
                """)
            return rows.map { row in
                RecordedLemma(lemmaID: row["entity_id"],
                              text: TextSanitizer.clean(row["text"], preserveLineBreaks: false) ?? "",
                              definition: TextSanitizer.clean(row["definition"], preserveLineBreaks: true),
                              mastery: row["mastery"], seenCount: row["seen_count"],
                              source: row["source"], updatedAt: row["updated_at"],
                              belief: row["belief"],
                              contextCount: row["context_count"] ?? 0,
                              eventCount: row["event_count"] ?? 0)
            }
        }
    }
```

**3b. `VocabularyListViewModel.swift`：**

- `SortOrder` 追加 case：

```swift
        case mastery = "掌握度高→低"
```

- `filtered` 的排序 switch 追加：

```swift
        case .mastery:
            return base.sorted { ($0.belief ?? -1) > ($1.belief ?? -1) }
```

- `state(of:)` 改名为 `markState(_:)` 并改概率优先（**同时更新 `filtered` / `countByState` 里的 `state(of: e)` 调用为 `markState(e)`**）：

```swift
    /// 统一状态判定（概率优先；无概率回退显式标记）。
    func markState(_ e: GraphQueries.RecordedLemma) -> WordMarkState {
        WordMarkState.from(
            belief: e.belief,
            mastery: e.mastery > 0 ? e.mastery : nil,
            seenCount: e.seenCount)
    }
```

- `beliefText(_:)` 改为走展示层：

```swift
    /// 概率百分比文案（nil = 尚无模型数据）。
    func beliefText(_ e: GraphQueries.RecordedLemma) -> String? {
        guard let belief = e.belief else { return nil }
        return MasteryPresentation.percentText(belief)
    }
```

**3c. `VocabularyListView.swift` 的 `row(_:)`：**

- 状态判定改：

```swift
        let state = vm.markState(e)
```

- **删除**裸 mastery 数值块（原 `if e.mastery > 0 { Text(String(format: "%.1f", e.mastery)) ... }`），把概率文本改为带档位色：

```swift
                    if let belief = e.belief {
                        Text(MasteryPresentation.percentText(belief))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(state.color)
                            .help(MasteryPresentation.helpText(belief))
                    }
```

- **替换**「阅读频次」块（原 `Image(systemName: "eye")` + `Text("\(e.seenCount) 次")`）为：

```swift
                    // 上下文多样性 + 事件数（取代旧的「阅读频次」）
                    HStack(spacing: 3) {
                        Image(systemName: "square.grid.2x2")
                        Text("\(e.contextCount) 个上下文 · \(e.eventCount) 次事件")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("上下文多样性：在复习/阅读/词典等不同场景出现过 \(e.contextCount) 个，累计 \(e.eventCount) 次事件。CD 研究表明多样性比单纯频次更能预测学习。")
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter VocabularyListViewModelTests 2>&1 | tail -8`
Expected: 全 PASS。

- [ ] **Step 5: 回归**

Run: `swift test --filter GraphQueriesVocabularyTests 2>&1 | tail -5`
Expected: 全 PASS（若既有断言构造了 `RecordedLemma`，新字段有默认值，无需改动）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/ECS/GraphQueries+Vocabulary.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyListViewModel.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyListView.swift \
        Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift
git commit -m "refactor(ui): 词表页改概率口径，频次改上下文多样性"
```

---
