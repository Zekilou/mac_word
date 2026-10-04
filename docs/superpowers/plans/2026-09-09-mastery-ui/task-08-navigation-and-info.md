# Task 8：导航与信息补齐（P1）

**Files:**
- Modify: `Sources/WordRecitingApp/UI/NavigationModel.swift`（新增「词典」子区）
- Modify: `Sources/WordRecitingApp/UI/ContentView.swift`（路由 + 布局修饰器收敛）
- Modify: `Sources/WordRecitingApp/UI/DeckManagerView.swift`（移除词典入口）
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyInitView.swift`（分段 IA）
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyListViewModel.swift`（筛选补「学习中」）
- Modify: `Sources/WordRecitingApp/UI/AnalyticsView.swift`（拆分两块）
- Test: `Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift`（追加）

**依赖：** Task 1–7。

**审计对照（`design-audit.md` P1）：** 词典入口埋在词库、无全局查词、词汇页两种心智模型同页、词表筛选缺「学习中」、分析页两个层级混一页、布局约定分散。

---

- [ ] **Step 1: 写失败测试**

在 `Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift` 末尾追加：

```swift
    func testFilterIncludesLearning() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: 0.50)

        let vm = VocabularyListViewModel(world: world)
        vm.filter = .learning

        XCTAssertEqual(vm.filtered.map(\.lemmaID), ["L1"])
    }

    func testLearningIsExcludedFromKnownAndUnknownFilters() throws {
        try seedEntry(lemmaId: "L1", text: "abandon", mastery: 2.0, belief: 0.50)

        let vm = VocabularyListViewModel(world: world)
        vm.filter = .known
        XCTAssertTrue(vm.filtered.isEmpty)

        vm.filter = .unknown
        XCTAssertTrue(vm.filtered.isEmpty)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter VocabularyListViewModelTests 2>&1 | tail -6`
Expected: FAIL（`type 'VocabularyListViewModel.Filter' has no member 'learning'`）。

- [ ] **Step 3: 实现**

**3a. 词表筛选补「学习中」——`VocabularyListViewModel.swift`：**

- `Filter` 追加 case：

```swift
        case learning = "学习中"
```

- `filtered` 的筛选 switch 追加：

```swift
            case .learning:
                if case .learning = state { matchFilter = true } else { matchFilter = false }
```

**3b. 词典提到主导航——`NavigationModel.swift`：**

- `AppSection` 追加 case（放在 `analytics` 之后，仍在「数据」区）：

```swift
    case dictionary = "词典"
```

- `zone` 的 switch 加：

```swift
        case .decks, .vocabulary, .synonyms, .rssSources, .analytics, .dictionary: return .data
```

- `icon` 的 switch 加：

```swift
        case .dictionary: return "character.book.closed"
```

**3c. `ContentView.swift`：**

- `contentView` 的 switch 加：

```swift
        case .dictionary: inset("词典", navWidth, topInset) { SystemDictionaryView(world: world) }
```

**3d. `DeckManagerView.swift`：** 删除 `SystemDictionaryRoute` 的 `navigationDestination` 与两个 `NavigationLink`（原第 34–36、73、91 行），并删除 `struct SystemDictionaryRoute: Hashable {}`（原第 181 行）。

**3e. 词汇页分段 IA——`VocabularyInitView.swift`：**

- 顶部说明改为区分两种用途（分段标题保持，但补一行副标题）：

```swift
            VStack(alignment: .leading, spacing: 2) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(tab == .initFlow
                     ? "一次性引导：生成易读段落，标出不认识的词，建立初始掌握度"
                     : "日常档案：查看、搜索、筛选所有有记录的词")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
```

> `tab` 的绑定名按文件实际变量调整。

**3f. 分析页拆分——`AnalyticsView.swift`：**

- `reviewSection` 的标题改为「复习表现（卡片维度）」，并在其前插入一个明显的分节说明：

```swift
            VStack(alignment: .leading, spacing: 4) {
                Text("复习表现").font(.headline)
                Text("卡片维度：与上面的词汇画像不是同一层级（这里是背诵调度数据）")
                    .font(.caption).foregroundStyle(.tertiary)
            }
```

- 弱词排行行内补词频带（`AnalyticsViewModel` 需要 `allLemmaFrequencies`）：

```swift
            Text(FrequencyBandPresentation.bandLabel(vm.band(for: w)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
```

`AnalyticsViewModel` 追加：

```swift
    /// 词频坐标（lemma → 行）。
    private(set) var frequencyByLemma: [EntityID: GraphQueries.LemmaFrequencyRow] = [:]

    /// 弱词行的词频带（nil = 无坐标）。
    func band(for stat: WeakLemmaStat) -> Int? {
        frequencyByLemma[stat.lemmaId]?.band
    }
```

并在 `reload()` 里加载 `frequencyByLemma = (try? world.graph.allLemmaFrequencies()) ?? [:]`。

> 若 `WeakLemmaStat` 没有 `lemmaId` 字段，改用该类型里实际存在的词元标识字段。

**3g. 布局修饰器收敛——`ContentView.swift`：**

- 把 `inset(_:_:_:_:)` 改名为 `appColumn` 并加 `@ViewBuilder` 文档注释，明确「新增页面必须走它」：

```swift
    /// 页面列壳：内容从导航栏结束处开始、列头从安全区下沿开始。
    /// @ai: 新增页面必须用它包裹，禁止自己算 navWidth / topInset。
    private func appColumn<Content: View>(
        _ title: String, _ navWidth: CGFloat, _ topInset: CGFloat,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: navWidth)
            ColumnShell(title: title) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

- 把 `contentView` 里全部 `inset(...)` 调用改为 `appColumn(...)`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter VocabularyListViewModelTests 2>&1 | tail -6`
Run: `swift test --filter AnalyticsViewModelTests 2>&1 | tail -6`
Expected: 全 PASS。

- [ ] **Step 5: 回归导航相关**

Run: `swift test --filter DeckManager 2>&1 | tail -5`
Run: `swift test --filter SystemDictionaryTests 2>&1 | tail -5`
Expected: 全 PASS（词典的 VM 逻辑没动，只是入口位置变了）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/UI/NavigationModel.swift \
        Sources/WordRecitingApp/UI/ContentView.swift \
        Sources/WordRecitingApp/UI/DeckManagerView.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyInitView.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyListViewModel.swift \
        Sources/WordRecitingApp/UI/AnalyticsView.swift \
        Sources/WordRecitingApp/UI/AnalyticsViewModel.swift \
        Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift
git commit -m "refactor(ui): 词典入主导航、词表筛选补学习中、分析页分层"
```

---
