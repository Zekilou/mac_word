# 回执：WordCore 收敛已完成

**写于** 2026-11-03 · **对应交接**：`docs/handoff/2026-11-03-word-core-consolidation.md`
**结论**：`WordCore` 已落地，4 个 DTO 全部派生自它；`belief` / `mastery` / `seen_count` 的 JOIN 从 8 处收敛到 **1 处**。
**验证**：`swift build` 0 warning（含 GRDB 依赖外）；`swift test` **905 tests / 10 skipped / 0 failures**（基线 895，新增 10 条契约测试）。

---

## 1. 实际做了什么

### 新增两个文件

| 文件 | 内容 |
|---|---|
| `Sources/WordRecitingApp/ECS/WordCore.swift` | 唯一词快照（13 个标量 + 嵌套 `CardSchedule`）；`WordCore.Card`（词快照 + cardId）；`plainText` / `markState` / `empty(lemmaId:)` |
| `Sources/WordRecitingApp/ECS/GraphQueries+WordCore.swift` | 唯一连接：`wordCoreJoin` + `wordCoreColumns(...)` + 两个行锚点 + 两个映射函数 + 单行 `wordCore(lemmaId:)` |

### 连接只写一份（关键）

```
wordCoreJoin                      ← belief / mastery / seen_count / 词频 / 事件聚合，全库唯一
wordCoreColumns(lemmaId:textA:textB:)  ← 列清单，别名固定（k/b/f/ev/t）
  ├─ wordCoreFromByLemma   （每词一行）→ recordedLemmas / wordFeatures / searchLemmas
  └─ wordCoreFromByCard    （每卡一行）→ dueCards / cardsInDeck / cardForLemma / cardsInDeck
```

两个行锚点**不是两个口径**：词侧连接共用同一段 `wordCoreJoin`，只在「行锚点」（lemma 还是 card）上各自声明一次。这正好回答了交接文档「注意事项 1 / 2」里提的两个坑：

1. `dueQueueFrom` 与词连接**没有合并**——`dueQueueFrom` 现在就是 `wordCoreFromByCard` 的别名（卡片行锚点唯一），`COALESCE(inst_edge.dst_id, c.id)` 的无边兜底保留在 `wordCoreColumnsByCard` 的 `lemmaId/textA/textB` 表达式里。
2. 「一张卡 vs 一个词」用**类型**表达，不用注释表达：按卡一行的查询返回 `WordCore.Card`，按词一行的返回 `WordCore`。`MIN(card.id)` 的按词聚合只在 byLemma 侧出现，多卡词不会在卡片列表里丢卡（有测试）。

### DTO 收敛结果

| 旧 | 新 | 说明 |
|---|---|---|
| `CardListItem`（10 字段） | `typealias CardListItem = WordCore.Card` | 身份仍是 cardId；补齐 band / updatedAt / eventCount |
| `RecordedLemma`（11 字段） | `struct { let word: WordCore; let source: String? }` | `source` 是 `comp_user_known` 独有的审计字段，不属于「词」本身；其余全部转发 |
| `LemmaCandidate`（3 字段） | `struct { let word: WordCore }` | 以前字段最少，现在与词表同口径 |
| `WordFeatures`（10 字段、无文本） | `typealias WordFeatures = WordCore` | 策略层零改动 |
| `LemmaDetail`（6 字段） | `struct { let word: WordCore; let pos: String?; let synonyms; let articles }` | 保持聚合视图，标量从 WordCore 取（详情与列表同口径，有测试） |

### UI 侧（按交接文档第 4 节）

- `FilterableAdapters.swift` 从「三个 DTO 各写一遍」改为 **`WordCoreBacked` 协议 + 一份默认实现**，DTO 只剩 `filterID`（身份）一行差异。
- 卡片浏览页 facets：`[.text, .definition, .mark, .band, .belief, .due, .seen, .sort]` —— **`.band` 已启用**（当初启用不了就是因为它缺字段）。
- 词汇表 facets：加上 `.band` 与 `.due` —— 交接文档完成标准里的两条都满足。

---

## 2. 完成标准核对

- [x] `WordCore` 存在，字段覆盖 13 个标量 + 1 个嵌套 schedule
- [x] `GraphQueries+WordCore.swift` 里只有一份连接逻辑
- [x] `belief` / `mastery` / `seen_count` 的 JOIN 从 8 处收敛到 1 处（grep 复核：其余命中全是「单表单列查询」如 `knownLemmaMastery` / `allMasteryBeliefs` / 聚合统计，不含 JOIN）
- [x] 4 个 UI DTO 都从 `WordCore` 派生
- [x] `FilterableAdapters.swift` 只剩一份实现
- [x] 卡片浏览页可启用 `[.band]`
- [x] 词汇表可启用 `[.band]` 与 `[.due]`
- [x] `swift test` 全绿，数量 905 ≥ 895
- [x] `swift build` 0 warning（顺手修掉 `RuleBasedGenerator` 里既有的 unused `originalSpan`）

---

## 3. 需要下一个会话注意的三件事

1. **`WordCore.Card.reps` 是 `Int?`，不是 `Int`。**
   nil = 这张卡没有 `comp_schedule_state` 行；这与收敛前 `CardListItem.reps: Int?` 的语义严格一致（`CardBrowserView` 用 `if card.reps != nil` 决定是否显示次数，`GenerateViewModel` 用 `(card.reps ?? 0) == 0` 判新卡）。改成非可选会静默改变这两处行为。

2. **`RecordedLemma.mastery` 保持「非可选、0 = 无记录」的历史读法**，而 `WordCore.mastery` 是 `Double?`。转发处用了 `word.mastery ?? 0`，这样 `mastery > 0 ? mastery : nil` 这类老调用点语义不变。若将来要统一成 Optional，需要同时改 `VocabularyListViewModel.markState` 与三处测试。

3. **`UI/` 下有一批文件不是本次改动**（`Study/` 新目录、`StudyView` / `StudyViewModel` / 设计系统替换 `Space`/`Type`/`Ink` 等）。
   我在中途发现工作区里有**另一个会话在并行改 UI**（词汇表与卡片浏览的 `FilterBar` 接线就是那边写的），所以本次只在必要时补了 facets 与状态口径，没有重写那些页面。收尾时请以 `git status` 为准合并，不要按文件回滚。

---

## 4. 新增测试

`Tests/WordRecitingAppTests/ECS/WordCoreTests.swift`（10 条）钉住四条硬约束：

1. **四种 DTO 同口径**：同一个 lazy 词在 card / recorded / candidate / features 上的词面、释义、掌握度、概率、词频、事件数与身份完全一致。
2. **无 `instantiates` 边**的卡片（CSV `front,back` 导入）仍有完整快照，且能进到期队列（`dueCards` 与 `studyStats.dueCount` 同口径，不给「今日到期 N 但队列为空」留复发口子）。
3. **一个词多张卡**：按卡出行不丢卡，按词出行只有一行且代表卡取 `MIN(card.id)`。
4. **卡片侧筛选维度齐全**：band / due / 概率在卡片行上真的可筛（这是收敛的直接动机）。

另有 `TextSanitizer` 兜底测试：脏词面在全部五个出口（含新加的 `lemmaDetail`）都被清洗。
