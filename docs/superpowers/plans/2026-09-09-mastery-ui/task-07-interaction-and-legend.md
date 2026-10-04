# Task 7：交互与图例统一（P0）

**Files:**
- Modify: `Sources/WordRecitingApp/UI/WordMarkState.swift`（加 `legendItems`）
- Create: `Sources/WordRecitingApp/UI/Components/WordMarkLegendView.swift`
- Modify: `Sources/WordRecitingApp/UI/ReadingView.swift`（图例收敛 + 去 alert + 右键菜单）
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyInitView.swift`（同上）
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateView.swift` + `GenerateView+ReadText.swift`（同上）
- Modify: `Sources/WordRecitingApp/UI/Components/SearchableChecklist.swift`（行尾徽章）
- Modify: `Sources/WordRecitingApp/UI/Creation/GenerateView+Columns.swift`（选词器传徽章）
- Modify: `Sources/WordRecitingApp/RSS/RSSViewModel.swift` / `UI/Init/VocabularyInitViewModel.swift` / `UI/Creation/GenerateViewModel+ArticleWords.swift`（左键统一动作）
- Test: `Tests/WordRecitingAppTests/UI/WordMarkStateTests.swift`（追加）
- Test: `Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift`（追加）

**依赖：** Task 1–6。

**审计对照（`design-audit.md` P0 #2/#5/#6）：**
- 图例颜色有两份实现（`ReadingView.swift:86-102` 手写）→ 收敛到 `WordMarkState.legendItems`。
- 用 alert 确认可逆操作（3 处）→ 改右键菜单。
- 选词器不显示词的状态（`GenerateView+Columns.swift:95-108`）→ 加徽章。

---

- [ ] **Step 1: 写失败测试**

**1a. 在 `Tests/WordRecitingAppTests/UI/WordMarkStateTests.swift` 末尾追加：**

```swift
    // MARK: - 图例统一

    func testLegendItemsCoverAllTiers() {
        let labels = WordMarkState.legendItems.map(\.label)
        XCTAssertEqual(labels, ["会", "学习中", "不会", "出现过", "未见"])
    }

    func testLegendColorsComeFromStateColors() {
        let items = WordMarkState.legendItems
        XCTAssertEqual(items[0].color, WordMarkState.known.color)
        XCTAssertEqual(items[1].color, WordMarkState.learning(0.5).color)
        XCTAssertEqual(items[2].color, WordMarkState.unknown.color)
    }
```

**1b. 在 `Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift` 末尾追加：**

```swift
    func testPickerStateIsDrivenByBelief() {
        let card = CardListItem(
            cardId: "C1", lemmaId: "L1", text: "abandon", definition: nil,
            dueAt: nil, intervalDays: nil, reps: nil,
            mastery: 2.0, seenCount: 0, belief: 0.10)

        XCTAssertEqual(vm.pickerState(for: card), .unknown)
    }

    func testPickerStateFallsBackToMastery() {
        let card = CardListItem(
            cardId: "C1", lemmaId: "L1", text: "abandon", definition: nil,
            dueAt: nil, intervalDays: nil, reps: nil,
            mastery: 2.0, seenCount: 0, belief: nil)

        XCTAssertEqual(vm.pickerState(for: card), .known)
    }
```

> `vm` 用该文件 `setUp` 里已有的实例。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter WordMarkStateTests 2>&1 | tail -6`
Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -6`
Expected: FAIL（`no member 'legendItems'` / `no member 'pickerState'`）。

- [ ] **Step 3: 实现**

**3a. `WordMarkState.swift` 末尾追加：**

```swift
extension WordMarkState {

    /// 图例项（全应用图例统一从这里取，禁止各页手写颜色）。
    struct LegendItem: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let color: Color
    }

    static var legendItems: [LegendItem] {
        [
            LegendItem(label: "会", color: WordMarkState.known.color),
            LegendItem(label: "学习中", color: WordMarkState.learning(0.5).color),
            LegendItem(label: "不会", color: WordMarkState.unknown.color),
            LegendItem(label: "出现过", color: WordMarkState.seen.color),
            LegendItem(label: "未见", color: WordMarkState.pending.color)
        ]
    }
}
```

**3b. 新建 `Sources/WordRecitingApp/UI/Components/WordMarkLegendView.swift`：**

```swift
import SwiftUI

/// 词块图例：统一从 `WordMarkState.legendItems` 取色，禁止各页手写。
struct WordMarkLegendView: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(WordMarkState.legendItems) { item in
                HStack(spacing: 3) {
                    Circle().fill(item.color.opacity(0.85)).frame(width: 7, height: 7)
                    Text(item.label).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}
```

**3c. 三处「左键 = 标不会，右键 = 改极端」。**

- `RSSViewModel.swift` 追加：

```swift
    /// 左键统一动作：标记为不会（可预测；改会走右键菜单）。
    func markUnknown(_ word: InitWord) {
        setExtreme(word, known: false)
    }
```

- `VocabularyInitViewModel.swift` 追加：

```swift
    /// 左键统一动作：标不会（写会话覆盖，提交时才落库）。
    func markUnknown(_ word: InitWord) {
        sessionStates[word.lemma] = false
    }
```

- `GenerateViewModel+ArticleWords.swift` 追加：

```swift
    /// 左键统一动作：标记为不会（立即落库）。
    func markUnknownArticleWord(_ token: ArticleWordToken) {
        sessionWordStates[token.lemma] = false
        persistArticleWordState(token)
    }
```

**3d. `ReadingView.swift`：**

- 删除 `@State private var confirmWord: InitWord?` 与整个 `.alert(...)` 块（原第 31–44 行）。
- `legend` 计算属性整体替换：

```swift
    private var legend: some View {
        WordMarkLegendView()
    }
```

- `wordChip(_:)` 的 Button 动作与结尾改为：

```swift
        return Button {
            vm.markUnknown(word)
        } label: {
            Text(word.surface)
                .font(.system(size: 16))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(state.color.opacity(0.85))
                .foregroundStyle(state == .pending ? Color.primary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("标为会") { vm.setExtreme(word, known: true) }
            Button("标为不会") { vm.setExtreme(word, known: false) }
        }
        .help(helpText(for: state))
```

- `helpText(for:)` 整体替换：

```swift
    private func helpText(for state: WordMarkState) -> String {
        switch state {
        case .known: return "已会（左键标不会；右键可改）"
        case .unknown: return "不会（右键可改为会）"
        case .learning(let belief): return "\(MasteryPresentation.helpText(belief))；左键标不会，右键改极端"
        case .seen: return "出现过未确认，模型尚无概率（左键标不会）"
        case .pending: return "未见（左键标不会）"
        }
    }
```

**3e. `VocabularyInitView.swift`：**

- 删除 `@State private var confirmWord: InitWord?` 与 `.alert(...)` 块（原第 33 行起）。
- `wordChip(_:)` 的 Button 动作与结尾改为：

```swift
        return Button {
            vm.markUnknown(word)
        } label: {
            Text(word.surface)
                .font(.system(size: 17))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    state == .pending
                        ? AnyShapeStyle(.quaternary.opacity(0.35))
                        : AnyShapeStyle(state.color.opacity(0.85))
                )
                .foregroundStyle(state == .pending ? Color.primary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("标为会") { vm.setSession(word, known: true) }
            Button("标为不会") { vm.setSession(word, known: false) }
        }
        .help(helpText(for: state))
```

- 顶部说明文案（原第 202 行）改为：

```swift
            Text("左键标不会 · 右键改会/不会 · 提交时统一落库")
                .font(.callout).foregroundStyle(.secondary)
```

**3f. `GenerateView+ReadText.swift` 与 `GenerateView.swift`：**

- `GenerateView.swift`：删除 `@State private var confirmArticleWord` 与 `.alert(...)` 块（原第 67 行起）。
- `GenerateView+ReadText.swift` 的 `stateWordChip(_:)` 改为：

```swift
        return Button {
            vm.markUnknownArticleWord(token)
        } label: {
            Text(token.surface)
                .font(.body)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(state.color.opacity(0.85))
                .foregroundStyle(state == .pending ? Color.primary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("标为会") { vm.setArticleWordExtreme(token, known: true) }
            Button("标为不会") { vm.setArticleWordExtreme(token, known: false) }
        }
        .help(articleWordHelpText(for: state))
```

**3g. `SearchableChecklist.swift`：**

- 属性区追加（带默认值，既有调用点不受影响）：

```swift
    /// 行尾徽章（可选）：返回 (文案, 颜色)；nil = 不显示。
    let badge: ((Item) -> (text: String, color: Color)?)? = nil
```

- `row(_:)` 的 `Spacer()` 之后追加：

```swift
                if let badge = badge?(item) {
                    Text(badge.text)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badge.color.opacity(0.14))
                        .clipShape(Capsule())
                }
```

**3h. `GenerateViewModel+ArticleWords.swift` 追加：**

```swift
    /// 选词器行状态（概率优先）。
    func pickerState(for card: CardListItem) -> WordMarkState {
        WordMarkState.from(belief: card.belief, mastery: card.mastery, seenCount: card.seenCount)
    }
```

**3i. `GenerateView+Columns.swift` 的 `SearchableChecklist(...)` 调用追加参数：**

```swift
                            badge: { card in
                                let state = vm.pickerState(for: card)
                                guard state != .pending else { return nil }
                                if let belief = card.belief {
                                    return (MasteryPresentation.percentText(belief), state.color)
                                }
                                return (state.label, state.color)
                            })
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter WordMarkStateTests 2>&1 | tail -6`
Run: `swift test --filter GenerateViewModelTests 2>&1 | tail -6`
Expected: 全 PASS。

- [ ] **Step 5: 回归三个词块页面**

Run: `swift test --filter RSSViewModelTests 2>&1 | tail -5`
Run: `swift test --filter VocabularyInitViewModelTests 2>&1 | tail -5`
Run: `swift test --filter GenerateArticleWordsTests 2>&1 | tail -5`
Expected: 全 PASS（若既有测试断言了 `toggle` 的三态循环，改为断言 `markUnknown`）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/UI/WordMarkState.swift \
        Sources/WordRecitingApp/UI/Components/WordMarkLegendView.swift \
        Sources/WordRecitingApp/UI/Components/SearchableChecklist.swift \
        Sources/WordRecitingApp/UI/ReadingView.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyInitView.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyInitViewModel.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateView.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateView+ReadText.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateView+Columns.swift \
        Sources/WordRecitingApp/UI/Creation/GenerateViewModel+ArticleWords.swift \
        Sources/WordRecitingApp/RSS/RSSViewModel.swift \
        Tests/WordRecitingAppTests/UI/WordMarkStateTests.swift \
        Tests/WordRecitingAppTests/UI/GenerateViewModelTests.swift
git commit -m "refactor(ui): 图例收敛、去可逆 alert、选词器显示状态"
```

---
