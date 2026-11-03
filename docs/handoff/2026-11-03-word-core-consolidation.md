# 交接：统一「一个词」的数据结构（WordCore）

**写于** 2026-11-03 · **给**：负责后端/ECS 层的会话
**目的**：把 4 个残缺的词 DTO 收敛成一个 `WordCore`，让 UI 层的统一筛选真正落地。

---

## ⚠️ 进度更新（2026-11-03 晚）

**另一个会话已完成第一轮**，`WordCore` 已落地（`Sources/WordRecitingCore/ECS/WordCore.swift`
+ `GraphQueries+WordCore.swift`），`GraphQueries+Features.swift` 已重写，
`dueCards` / `cardsInDeck` 已改为复用新的连接逻辑。

**UI 侧适配层已简化**：`FilterableAdapters.swift` 现在只剩一个协议 `WordCoreBacked`
（要求一个 `word: WordCore` 属性）+ 一份共享实现，派生 DTO 只声明 `filterID`。

### 仍然缺的（这才是接下来要做的）

| 类型 | 缺什么 | 影响 |
|---|---|---|
| `CardListItem` | `band` / `rank` / `updatedAt` 裸字段 | 卡片浏览页无法启用 `.band` 筛选 |
| `RecordedLemma` | `band` / `schedule` 裸字段 | 词汇表无法启用 `.band` / `.due` 筛选 |
| `WordFeatures` | `text` / `definition` / `mastery` | 它仍只是「调度特征」，不是完整词快照 |
| `LemmaDetail` | `belief` / `band` | 详情面板无法展示概率与词频 |

**对应测试已写好但被 skip**（`Tests/.../ECS/WordCoreTests.swift`）：
- `testCardRowExposesEveryFilterableFacet`
- `testRecordedLemmaRowExposesBandAndSchedule`

实现上面几项后，把这两处的 `XCTSkipIf(true, ...)` 删掉，测试会开始真正校验。

---

## 一句话背景

UI 层正在做统一筛选（`FilterBar`）。筛选需要「一个词」暴露同一组属性，但现在的 4 个 DTO 字段残缺各不相同，**没有任何一个字段是全的**。UI 侧已用临时适配层（`FilterableAdapters.swift`）顶上，其中缺失的字段现在返回空值——对应的筛选项在部分列表里是「沉默不生效」的。

---

## 现状：4 个 DTO + 1 个调度契约

| 文件 | 类型 | 身份 | 字段数 | 构造点 |
|---|---|---|---|---|
| `ECS/GraphQueryTypes.swift` | `CardListItem` | **cardId**（Card 节点） | 10 | **9** |
| `ECS/GraphQueries+Vocabulary.swift` | `RecordedLemma` | lemmaID | 11 | 1 |
| `ECS/GraphQueryTypes.swift` | `LemmaCandidate` | lemmaId | 3 | 1 |
| `ECS/GraphQueryTypes.swift` | `LemmaDetail` | lemmaId | 6（含 2 个集合） | 1 |
| `Scheduling/WordFeatures.swift` | `WordFeatures` | lemmaId | 10（无文本） | **8** |

### 字段矩阵（`●` 有 · `—` 无）

| 字段 | CardListItem | RecordedLemma | LemmaCandidate | LemmaDetail | WordFeatures |
|---|---|---|---|---|---|
| lemmaId | ● | ● | ● | ● | ● |
| cardId | ● | — | — | — | ●(嵌套) |
| text（词面） | ● | ● | ● | ● | **—** |
| definition | ● | ● | ● | ● | **—** |
| pos（词性） | — | — | — | ● | — |
| mastery（显式标记） | ● | ● | — | — | **—** |
| belief（BKT 概率） | ● | ● | — | — | ● |
| band（词频带） | **—** | **—** | — | — | ● |
| rank（全表排名） | **—** | **—** | — | — | ● |
| seenCount | ● | ● | — | — | **—** |
| eventCount | — | ● | — | — | ● |
| contextCount | — | ● | — | — | ● |
| lastEventAt | — | — | — | — | ● |
| updatedAt | — | ● | — | — | **—** |
| dueAt | ● | — | — | — | ●(嵌套) |
| intervalDays | ● | — | — | — | ●(嵌套) |
| reps | ● | — | — | — | ●(嵌套) |
| lapses | — | — | — | — | ●(嵌套) |
| lastReviewedAt | — | — | — | — | ●(嵌套) |
| synonyms | — | — | — | ● | — |
| articles | — | — | — | ● | — |

### 真正的病

不是「结构太多」，是 **JOIN 逻辑被抄了 8 遍**：

- `belief` 在 **8 处** SQL 里各 JOIN 一次 `comp_mastery_belief`
- `mastery` / `seen_count` 在至少 **4 处**各 JOIN 一次 `comp_user_known`
- 同一个「卡片 + 词面 + 排程」的连接在 `dueQueueFrom` / `cardsInDeck` / `cardForLemma` 里写了 3 遍

结果：换一个口径要改 8 个地方。备忘录里记过多次「口径分裂」事故（最近一次是 `dueCards` 用 INNER JOIN 而 `dueCount` 用 LEFT JOIN，导致「今日到期 N 张但队列为空」）。

`dueQueueFrom` 这个共享常量已经证明了正确做法——**连接只写一份**。

---

## 目标结构

```
WordCore  ← 唯一词快照，一段 SQL 拼出来
├── lemmaId: EntityID
├── text: String
├── definition: String?
├── mastery: Double?
├── belief: Double?
├── band: Int?
├── rank: Int?
├── seenCount: Int
├── eventCount: Int
├── contextCount: Int
├── lastEventAt: Date?
├── updatedAt: Date?
└── schedule: CardSchedule?      （沿用 WordFeatures.CardSchedule）

CardListItem  = WordCore + cardId      ← Card 身份不能丢
RecordedLemma = WordCore               ← 或直接 typealias
LemmaCandidate= WordCore               ← 或轻量子集
WordFeatures  = WordCore               ← 保留这个名字，策略层零改动
LemmaDetail   = WordCore + synonyms + articles   ← 聚合视图，不合并
```

### 为什么不合并成一个

1. **身份不同**：`CardListItem.id` 是 cardId，其余是 lemmaId。一个词在 3 个词库里可以有 3 张卡，合并会把这个歧义渗到所有调用点。
2. **`LemmaDetail` 是聚合视图**：它带 `[SynonymInfo]` + `[ArticleHit]` 两个集合。让列表 DTO 背上它们，列表查询会为不显示的数据去 JOIN。
3. **聚合成本**：`recordedLemmas` 里的 `COUNT(DISTINCT region_id)` 子查询有成本，不该让每个列表都付。

---

## 需要改的文件

### 1. 新建 `Sources/WordRecitingApp/ECS/WordCore.swift`

```swift
struct WordCore: Sendable, Equatable, Identifiable {
    var id: EntityID { lemmaId }
    let lemmaId: EntityID
    let text: String
    let definition: String?
    let mastery: Double?
    let belief: Double?
    let band: Int?
    let rank: Int?
    let seenCount: Int
    let eventCount: Int
    let contextCount: Int
    let lastEventAt: Date?
    let updatedAt: Date?
    let schedule: Schedule?

    struct Schedule: Sendable, Equatable {
        let cardId: EntityID
        let dueAt: Date?
        let intervalDays: Double?
        let reps: Int
        let lapses: Int
        let lastReviewedAt: Date?
    }
}
```

### 2. 新建 `Sources/WordRecitingApp/ECS/GraphQueries+WordCore.swift`

一个共享 FROM 常量 + 一个 map 函数，供所有查询复用：

```swift
extension GraphQueries {
    /// 唯一的「词 + 掌握度 + 概率 + 词频 + 事件 + 排程」连接。
    /// @ai: 与 dueQueueFrom 同款思路——连接只写一份。
    ///      新增字段时只改这里，4 个查询自动跟上。
    static let wordCoreFrom = """
    FROM nodes n
    LEFT JOIN comp_text t             ON t.entity_id = n.id
    LEFT JOIN comp_user_known k       ON k.entity_id = n.id
    LEFT JOIN comp_mastery_belief b   ON b.entity_id = n.id
    LEFT JOIN comp_lemma_frequency f  ON f.entity_id = n.id
    LEFT JOIN (SELECT lemma_id, COUNT(*) AS event_count,
                      COUNT(DISTINCT region_id) AS context_count,
                      MAX(occurred_at) AS last_event_at
               FROM comp_word_event GROUP BY lemma_id) ev ON ev.lemma_id = n.id
    LEFT JOIN (SELECT inst.dst_id AS lemma_id, MIN(card.id) AS card_id,
                      ss.due_at, ss.interval_days, ss.reps, ss.lapses,
                      ss.last_reviewed_at
               FROM edges inst
               JOIN nodes card ON card.id = inst.src_id AND card.kind = 'card'
               LEFT JOIN comp_schedule_state ss ON ss.entity_id = card.id
               WHERE inst.rel_type = 'instantiates'
               GROUP BY inst.dst_id) c ON c.lemma_id = n.id
    """

    /// 列清单（与 wordCoreFrom 配套）。
    static let wordCoreColumns = """
    n.id AS lemma_id, t.text_a AS text, t.text_b AS definition,
    k.mastery, k.seen_count, b.belief,
    f.band, f.freq_rank AS rank,
    COALESCE(ev.event_count, 0) AS event_count,
    COALESCE(ev.context_count, 0) AS context_count,
    ev.last_event_at, k.updated_at,
    c.card_id, c.due_at, c.interval_days, c.reps, c.lapses, c.last_reviewed_at
    """
}
```

> 注意：`card_id` 子查询用 `GROUP BY lemma_id` 取 `MIN(card.id)` 会在一个词有多张卡时丢掉其余卡。现有 `wordFeatures` 就是这么做的（注释写「一个 Lemma 只取一张卡」）。**如果要让 `CardListItem` 保持「每卡一行」，就必须按 card 而不是按 lemma 来拼**——见下节注意事项。

### 3. 改造点（按顺序）

| # | 文件 | 改什么 |
|---|---|---|
| 1 | `ECS/GraphQueries+Features.swift` | `mapFeatures` 改成产出 `WordCore`；`wordFeatures` 返回 `[EntityID: WordCore]` |
| 2 | `Scheduling/WordFeatures.swift` | 改成 `typealias WordFeatures = WordCore`，或保留 struct 但字段对齐 |
| 3 | `ECS/GraphQueries+Study.swift` | `dueCards` / `cardForLemma` 复用 `wordCoreFrom`；**注意按 card 拼，不要按 lemma** |
| 4 | `ECS/GraphQueries+Vocabulary.swift` | `recordedLemmas` 复用 `wordCoreFrom` |
| 5 | `ECS/GraphQueries+Synonyms.swift` | `searchLemmas` 复用（前缀搜索保留） |
| 6 | `ECS/GraphQueries+Cards.swift` | `lemmaDetail` 保持聚合视图，只把标量字段改为从 WordCore 取 |

### 4. UI 侧收尾（后端完成后我来做，或你直接做）

删掉 `Sources/WordRecitingApp/UI/DesignSystem/FilterableAdapters.swift` 里的三个 extension，只在 `WordCore` 上保留一份 conformance：

```swift
extension WordCore: FilterableWord {
    var filterID: String { lemmaId }
    var wordText: String { text }
    var wordDefinition: String? { definition }
    var wordMark: WordMarkState {
        WordMarkState.from(belief: belief, mastery: mastery, seenCount: seenCount)
    }
    var wordBelief: Double? { belief }
    var wordBand: Int? { band }
    var wordSeenCount: Int { seenCount }
    var wordEventCount: Int { eventCount }
    var wordDueAt: Date? { schedule?.dueAt }
    var wordReps: Int { schedule?.reps ?? 0 }
    var wordUpdatedAt: Date? { updatedAt }
}
```

---

## 注意事项 / 坑

1. **`dueQueueFrom` 与 `wordCoreFrom` 的关系**。前者专用于「到期队列」，用了 `LEFT JOIN` 让没有 `instantiates` 边的 CSV 卡也能进队列；后者是「词」的全量连接。**不要直接合并这两个常量**——`dueQueueFrom` 的 COALESCE 兜底（`COALESCE(inst_edge.dst_id, c.id)`）是为无边的卡准备的，`wordCoreFrom` 按 lemma 拼时用不上。保留两个，但让 `dueCards` 的标量字段从 `wordCoreFrom` 取。

2. **一张卡 vs 一个词**。`dueCards` / `cardsInDeck` 是「每张卡一行」，`recordedLemmas` 是「每个词一行」。`wordCoreFrom` 的卡片子查询按 lemma 聚合，**不能直接用于前者**。要么给 `wordCoreFrom` 加一个 `byCard` 变体，要么让卡片侧查询继续自己拼但复用 `wordCoreColumns`。

3. **`TextSanitizer` 必须继续调用**。所有 query 输出词面/释义都要过 `TextSanitizer.clean`（`text_a` 单行、`text_b` 保留换行）。备忘录 v7/v8/v9 迁移就是为这个，别在新代码里漏掉。

4. **测试**。改动会波及：
   - `Tests/.../UI/StudyViewModelTests.swift`
   - `Tests/.../ECS/StudySystemTests.swift`
   - `Tests/.../ECS/RegionWiringTests.swift`
   - `Tests/.../Scheduling/RandomPickStrategyTests.swift`
   - `Tests/.../UI/GenerateViewModelTests.swift`
   - `Tests/.../GenerateAndCardBrowserTests.swift`

   `CardListItem` 有 9 个构造点、`WordFeatures` 有 8 个，这些构造点全都要跟着改。建议**先加字段并给默认值**，让旧构造点继续编译，再逐个收敛。

5. **验证基线**：当前 `swift test` = **895 tests / 10 skipped / 0 failures**。改完必须不低于这个数。

---

## 完成标准

- [ ] `WordCore` 存在，字段覆盖上表全部 13 个标量 + 1 个嵌套 schedule
- [ ] `GraphQueries+WordCore.swift` 里只有**一份**连接逻辑
- [ ] `belief` / `mastery` / `seen_count` 的 JOIN 从 8 处收敛到 1 处
- [ ] 4 个 UI DTO 都从 WordCore 派生（或本身就是 WordCore + 少量额外字段）
- [ ] `FilterableAdapters.swift` 里三个临时 extension 删除，只剩 WordCore 一份
- [ ] 卡片浏览页可以启用 `[.band]` 筛选（现在启用不了，因为 CardListItem 没有 band）
- [ ] 词汇表可以启用 `[.band]` 与 `[.due]` 筛选（现在启用不了）
- [ ] `swift test` 全绿，数量 ≥ 895
- [ ] `swift build` 0 warning

---

## UI 侧现状（供参考，不需要你改）

已建好的设计系统在 `Sources/WordRecitingApp/UI/DesignSystem/`：

| 文件 | 内容 |
|---|---|
| `Tokens.swift` | `Space` / `Radius` / `Type` / `Ink` / `Surface` / `Stroke` |
| `WordFilter.swift` | `FilterableWord` 协议、`WordFacet`、`ListFilter`、各种 Bucket |
| `FilterBar.swift` | `FilterBar` / `WordListPane` / `WordRow` |
| `Primitives.swift` | `Chip` / `WordMarkBadge` / `StatusDot` / `Rule` / `KeyHint` |
| `Containers.swift` | `Card` / `Panel` / `Section` / `PageScaffold` / `SplitPane` / `ListRow` / `EmptyState` |
| `DataDisplay.swift` | `StatTile` / `Meter` / `SegmentedMeter` / `KeyValueRow` / `Phonetic` |
| `FilterableAdapters.swift` | **过渡脚手架，你完成后我删** |

页面接入方式（你补完字段后，这些面板自动获得新筛选项，无需改页面代码）：

```swift
WordListPane(
    items: vm.words,
    filter: $vm.filter,
    facets: [.text, .definition, .mark, .band, .belief, .seen, .sort],
    emptyTitle: "还没有词汇记录"
) { word in
    WordRow(text: word.wordText, definition: word.wordDefinition,
            mark: word.wordMark) { /* trailing */ }
}
```
