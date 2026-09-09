# Task 4：接入造文选词 + 选词器 UI + 设置项

**Files:**
- Modify: `Sources/WordRecitingApp/Settings/AppSettings.swift`（`wordScoringID`）
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift`（`wordScoringID` + `randomPick` 走策略）
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateView+PickerColumn.swift`（策略下拉）
- Test: `Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift`（追加）

**依赖：** Task 3。

**默认行为不变**：`wordScoringID == .random` 时 `randomPick` 仍是随机选词。

---

- [ ] **Step 1: 写失败测试**

在 `Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift` 末尾追加：

```swift
    // MARK: - 选词策略（Task 4）

    private func seedFeature(lemmaId: String, belief: Double?, band: Int? = nil) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        if let belief {
            try world.registry.upsertComponent(MasteryBeliefComponent(
                entityId: lemmaId, belief: belief, opportunities: 1,
                lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        }
        if let band {
            try world.registry.upsertComponent(LemmaFrequencyComponent(
                entityId: lemmaId, band: band, freqRank: band * 1000, source: "test"))
        }
    }

    private func cardItem(_ cardId: String, _ lemmaId: String, _ text: String) -> CardListItem {
        CardListItem(cardId: cardId, lemmaId: lemmaId, text: text, definition: nil,
                     dueAt: nil, intervalDays: nil, reps: nil, mastery: nil, seenCount: 0)
    }

    @MainActor func testRandomPickCriticalWordsPrefersEdgeOfKnowing() throws {
        try seedFeature(lemmaId: "L-edge", belief: 0.5)
        try seedFeature(lemmaId: "L-known", belief: 0.95)
        try seedFeature(lemmaId: "L-unknown", belief: 0.05)

        let vm = makeVM()
        vm.selectedDeckId = "deck-1"
        vm.deckCards = [
            cardItem("C1", "L-edge", "edge"),
            cardItem("C2", "L-known", "known"),
            cardItem("C3", "L-unknown", "unknown")
        ]
        vm.randomCount = 1
        vm.wordScoringID = .criticalWords

        XCTAssertEqual(vm.randomPick(), ["L-edge"])
    }

    @MainActor func testRandomPickFrequencyTierPrefersHighFrequency() throws {
        try seedFeature(lemmaId: "L-1k", belief: nil, band: 1)
        try seedFeature(lemmaId: "L-25k", belief: nil, band: 25)

        let vm = makeVM()
        vm.selectedDeckId = "deck-1"
        vm.deckCards = [cardItem("C1", "L-1k", "the"), cardItem("C2", "L-25k", "zebra")]
        vm.randomCount = 1
        vm.wordScoringID = .frequencyTier

        XCTAssertEqual(vm.randomPick(), ["L-1k"])
    }

    @MainActor func testRandomPickKeepsWordFilterAsPreFilter() throws {
        try seedFeature(lemmaId: "L-edge", belief: 0.5)

        let vm = makeVM()
        vm.selectedDeckId = "deck-1"
        vm.deckCards = [cardItem("C1", "L-edge", "edge")]
        vm.randomCount = 5
        vm.wordFilter = .learned          // reps 全为 nil → 池为空
        vm.wordScoringID = .criticalWords

        XCTAssertTrue(vm.randomPick().isEmpty)
    }

    @MainActor func testWordScoringIDRoundTripsThroughSettings() {
        let vm = makeVM()
        vm.wordScoringID = .criticalWords
        vm.persistSettings()

        XCTAssertEqual(AppSettings(defaults: defaults).wordScoringID, .criticalWords)
    }
```

> 复用该文件已有的 `makeVM()` / `world` / `defaults`。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -8`
Expected: FAIL（`value of type 'GenerateViewModel' has no member 'wordScoringID'`）。

- [ ] **Step 3: 实现**

**3a. `AppSettings.swift`：**

- `Key` 枚举末尾追加：

```swift
        static let wordScoringID = "settings.wordScoringID"
```

- 属性区追加（放在 `schedulerID` 之后）：

```swift
    /// 选词打分策略（默认随机，与升级前一致）。
    var wordScoringID: WordScoringID {
        get {
            guard let raw = defaults.string(forKey: Key.wordScoringID),
                  let id = WordScoringID(rawValue: raw) else { return .random }
            return id
        }
        set { defaults.set(newValue.rawValue, forKey: Key.wordScoringID) }
    }
```

- 重置列表（`Key.defaultWordFilter, Key.defaultRandomCount,` 那一段）追加 `Key.wordScoringID,`。

**3b. `GenerateViewModel.swift`：**

- 属性区（`var randomCount: Int = 10` 之后）追加：

```swift
    /// 选词打分策略（默认随机，与升级前一致）。
    var wordScoringID: WordScoringID = .random
```

- `init` 里 `generatorTier = settings.generatorTier` 之后追加：

```swift
        wordScoringID = settings.wordScoringID
```

- `persistSettings()` 末尾追加：

```swift
        settings.wordScoringID = wordScoringID
```

- `randomPick()` 整体替换：

```swift
    /// 从当前词库按筛选条件选 randomCount 个词（按选词策略打分），并入已选集合（不重复）。
    /// @ai: WordFilter 仍是预过滤（全部/未学过/学过）；打分交给 WordScoringStrategy。
    @discardableResult
    func randomPick() -> [EntityID] {
        guard selectedDeckId != nil else { return [] }
        let pool = deckCards.filter { card in
            switch wordFilter {
            case .all: return true
            case .unlearned: return (card.reps ?? 0) == 0
            case .learned: return (card.reps ?? 0) > 0
            }
        }
        guard !pool.isEmpty else { return [] }

        let features: [WordFeatures]
        do {
            let byId = try world.graph.wordFeatures(lemmaIds: pool.map(\.lemmaId))
            features = pool.compactMap { byId[$0.lemmaId] }
        } catch {
            errorMessage = "读取词元特征失败：\(error)"
            return []
        }

        let picked = WordSelector.top(
            max(1, randomCount),
            from: features,
            strategy: SchedulingRegistry.scoring(wordScoringID),
            context: ScoringContext(purpose: .articleTargets,
                                    now: Date(), bandWindow: nil))
        pickedLemmaIds.formUnion(picked)
        return picked
    }
```

**3c. `GenerateView+PickerColumn.swift` 的 `randomSelector`：**

- 在「范围」Picker 之后插入策略 Picker：

```swift
            Picker("选词策略", selection: $vm.wordScoringID) {
                ForEach(WordScoringID.allCases, id: \.rawValue) { id in
                    Text(label(for: id)).tag(id)
                }
            }
            .labelsHidden()
```

- 底部说明文案改为：

```swift
            Text("从「\(vm.wordFilter.label)」的词中按「\(label(for: vm.wordScoringID))」选 \(max(1, vm.randomCount)) 个作为目标词")
                .font(.caption2).foregroundStyle(.tertiary)
```

- 「随机选词」按钮文案与图标改为随策略变化：

```swift
                } label: {
                    Label(vm.wordScoringID == .random ? "随机选词" : "按策略选词",
                          systemImage: vm.wordScoringID == .random ? "dice" : "target")
                }
```

- 文件内追加辅助：

```swift
    /// 策略中文名（选词器展示）。
    private func label(for id: WordScoringID) -> String {
        switch id {
        case .random: return "随机"
        case .criticalWords: return "临界词优先"
        case .frequencyTier: return "词频优先"
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -8`
Run: `swift test --filter AppSettingsTests 2>&1 | tail -5`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/Settings/AppSettings.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateView+PickerColumn.swift \
        Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift
git commit -m "feat(ui): 造文选词接入可插拔打分策略"
```

---
