# 可插拔调度层（Scheduling Layer）设计

> 状态：待评审 · 日期：2026-09-09 · 方案：窄接口 + 可组合权重

## 1. 问题

应用已经积累了三类新资产：

- **BKT 后验概率**（`comp_mastery_belief.belief`）
- **词频坐标**（`comp_lemma_frequency.band/rank`，BNC/COCA 1k~25k）
- **全量词事件流**（`comp_word_event`：seen/lookup/mark/quiz + region + trust）

但**决策层仍是单轨硬编码**：

| 管线 | 现状 | 没用上的资产 |
|---|---|---|
| 复习排期 `StudySystem` | 固定简化 SM-2（`factor` 2.5 起，写死公式）；`SchedulerID.fsrsV4` 是空壳 | 概率、词频、`elapsed_days` |
| 造文选词 `GenerateViewModel.randomPick` | `pool.shuffled().prefix(N)` **纯随机**；池只按 `reps` 0/1 过滤 | 概率（临界词）、词频带、到期 |
| 初始化段落 `VocabularyInitGenerator` | prompt 里硬编码「只用高频基础词」 | 真实词频表 |
| 阅读/RSS `extractWords` | 无难度过滤，全量记 `seen` | 词频带 |

结果：新数据只是被**展示**，没有被**决策**消费。

## 2. 目标 / 非目标

**目标**
- 把「选什么词 / 隔多久再考」从硬编码规则抽成**可插拔策略**。
- 策略统一消费「概率 + 词频 + 事件流 + 到期」。
- 设置页可切换策略；默认值保持现有手感（升级不改变默认行为）。
- 所有策略是**纯函数**，可单测。

**非目标（本设计不做）**
- 不换数据库 schema（`comp_schedule_state.stability/difficulty` 已是 FSRS 形状，够用）。
- 不引入机器学习拟合（BKT 参数拟合仍留阶段三）。
- 不在本轮实现 FSRS（留 S5，见 §7）。

## 3. 架构

三层，自下而上：

```
特征层  WordFeatures / WordFeaturesProvider   ← 一次查全，策略共享
决策层  WordScoringStrategy  （选词：打分）
        ReviewIntervalPolicy （排期：算下一次间隔）
注册层  SchedulingRegistry + 设置项            ← id → 实现
```

关键约束：**策略不碰数据库**。它只接收 `WordFeatures` 值类型，返回分数或新的调度状态。查询全在特征层完成。

## 4. 特征层

### 4.1 值类型

`Sources/WordRecitingApp/Scheduling/WordFeatures.swift`

```swift
/// 一个词元在决策时需要的全部特征（词频 + 概率 + 事件流 + 卡片调度）。
struct WordFeatures: Sendable, Equatable {
    let lemmaId: EntityID
    /// BKT 后验概率；nil = 尚无事件。
    let belief: Double?
    /// 词频带 1..25；nil = 无坐标（词表外或词表未加载）。
    let band: Int?
    /// 全表排名。
    let rank: Int?
    /// 词事件总数。
    let eventCount: Int
    /// 不同 region 数（上下文多样性 CD）。
    let contextCount: Int
    /// 最近一次事件时间。
    let lastEventAt: Date?
    /// 卡片调度状态；无卡 = nil。
    let card: CardSchedule?

    struct CardSchedule: Sendable, Equatable {
        let cardId: EntityID
        let dueAt: Date?
        let reps: Int
        let lapses: Int
        let intervalDays: Double?
        let lastReviewedAt: Date?
    }
}
```

### 4.2 查询

`GraphQueries+Features.swift`（沿用「db 版本 + 便捷版本」约定）：

```swift
func wordFeatures(_ db: Database, lemmaIds: [EntityID]) throws -> [EntityID: WordFeatures]
func wordFeatures(lemmaIds: [EntityID]) throws -> [EntityID: WordFeatures]
func allWordFeatures(_ db: Database) throws -> [EntityID: WordFeatures]
```

实现：一次 SQL，`comp_mastery_belief` LEFT JOIN `comp_lemma_frequency`，再 LEFT JOIN 事件聚合（`COUNT(*)` / `COUNT(DISTINCT region_id)` / `MAX(occurred_at)`），再 LEFT JOIN 卡片（`instantiates` → `comp_schedule_state`）。**N 个词只有一次查询。**

## 5. 决策层

### 5.1 选词打分

```swift
/// 打分上下文：策略据此区分用途。
struct ScoringContext: Sendable {
    enum Purpose: String, Sendable { case articleTargets, readingHighlight, initParagraph }
    let purpose: Purpose
    let now: Date
    /// 期望词频带窗口（nil = 不限）。
    let bandWindow: ClosedRange<Int>?
}

/// 分数越高越优先。确定性纯函数。
protocol WordScoringStrategy: Sendable {
    var id: WordScoringID { get }
    func score(_ f: WordFeatures, context: ScoringContext) -> Double
}
```

**取词方式由调用方决定**（不是策略的职责）：

- `topN(n)`：按分数降序取前 N（造文选词）
- `threshold(t)`：取分数 ≥ t（阅读高亮）
- `weightedSample(n)`：按分数加权采样（后续可选）

首批策略：

| id | 含义 | 打分 |
|---|---|---|
| `random` | 复刻旧行为 | `Double.random(in: 0...1)` |
| `criticalWords` | **临界词优先**：刚好在学、又不太熟的词最该练 | `belief == nil ? 0.5 : 1 - abs(belief - 0.5) / 0.5` |
| `frequencyTier` | **词频分层**：`initParagraph` 只取高频带；`articleTargets` 默认高频优先 | `band == nil ? 0 : 1 - (band - 1) / 24`；带窗口外直接 0 |

> `criticalWords` 的动机：概率 0.5 附近的词处在「会不会的边缘」，练它的边际收益最高；两端（0.05 / 0.95）练了几乎不涨。

### 5.2 排期

```swift
/// 算下一次调度状态。纯函数（不改 DB，由调用方写回）。
protocol ReviewIntervalPolicy: Sendable {
    var id: ReviewPolicyID { get }
    func next(state: ScheduleStateComponent, rating: Rating,
              features: WordFeatures, now: Date) -> ScheduleStateComponent
}
```

| id | 含义 |
|---|---|
| `sm2` | 语义正确的 SM-2（**复刻现有公式**，保证默认手感不变） |
| `sm2Frequency` | SM-2 + 词频/概率调制（见下） |

`sm2Frequency` 的调制（**启发式，非文献常数**，与项目既有诚实标注一致）：

- 高频词 `band ≤ 3`：间隔 × 1.3（语料中自然复现多，可少复习）
- 低频词 `band ≥ 10`：间隔 × 0.8（复现少，需要更勤）
- 模型高置信 `belief ≥ 0.9` 且 `rating ≥ good`：额外 × 1.5（模型认为已掌握，拉长）
- 无词频坐标 / 无概率：不加成（退化为纯 SM-2）

### 5.3 枚举与注册

`AppTypes.swift` 追加（**合同文件，只追加到末尾**）：

```swift
/// 复习排期策略。
enum ReviewPolicyID: String, Sendable, Codable, CaseIterable {
    case sm2
    case sm2Frequency = "sm-2-frequency"
}

/// 选词打分策略。
enum WordScoringID: String, Sendable, Codable, CaseIterable {
    case random
    case criticalWords = "critical-words"
    case frequencyTier = "frequency-tier"
}
```

```swift
enum SchedulingRegistry {
    static func reviewPolicy(_ id: ReviewPolicyID) -> any ReviewIntervalPolicy
    static func scoring(_ id: WordScoringID) -> any WordScoringStrategy
}
```

## 6. 接入点

| 接入点 | 改动 |
|---|---|
| `StudySystem` | 不再写死公式；`StudyOp` 增加 `policyID: ReviewPolicyID`（由 `StudyViewModel` 从设置读入——System 不碰 UI/设置），调 `policy.next(...)` 得到新 `ScheduleStateComponent`，其余（写 `review_event` + `produces` 边）不变 |
| `GenerateViewModel.randomPick` | 池 → `WordFeatures` → 策略打分 → 取 top-N；`WordFilter` 保留为**预过滤**（全部/未学过/学过） |
| 选词器 UI | 显示当前策略 + 「按策略重选」；随机/临界/词频三选一 |
| `VocabularyInitGenerator` | `ScoringContext.purpose = .initParagraph` + `bandWindow = 1...3` |
| `ReadingView` | 高亮用 `threshold`（可选，后续） |
| 设置页 | 两个下拉：复习策略（沿用 `settings.schedulerID`）/ 选词策略（新增 `settings.wordScoringID`） |

## 7. 落地顺序（每步独立可验证）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **S1** | 特征层：`WordFeatures` + `GraphQueries+Features` | 一次查询拿全；N 词 1 次 SQL；纯值类型 round-trip |
| **S2** | 选词策略：协议 + 3 个实现 + `randomPick` 接入 + 选词器 UI + 设置项 | `criticalWords` 下优先选 0.2~0.85 的词；`frequencyTier` 下 `initParagraph` 只出 ≤3k 带 |
| **S3** | 排期策略：协议 + `sm2` / `sm2Frequency` + `StudySystem` 接入 + 设置项 + 旧设置迁移 | 默认 `sm2` 与现有行为逐字一致；`sm2Frequency` 下高频词间隔更长 |
| **S4**（后续） | 内容侧：初始化段落 band 窗口 + 阅读高亮阈值 | — |
| **S5**（后续） | FSRS：`FSRSIntervalPolicy`（D/S/R + 目标保留率反解） | — |

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| 改排期会改变现有复习手感 | 默认 `sm2` **逐字复刻**现有公式；`sm2Frequency` 需用户显式切换 |
| 词频表未加载 | 所有策略对 `band == nil` 走保守分支（不加成 / 排后） |
| 特征查询变慢 | 一次批量 SQL + 现有索引（`comp_word_event(lemma_id, occurred_at)`、`comp_lemma_frequency` PK） |
| 策略随机性导致测试不稳 | 新策略全部确定性；`random` 只断言范围 |
| 与并发写入冲突 | 新文件集中在 `Scheduling/` 目录，少碰既有大文件 |

## 9. 测试策略

- **特征层**：批量查询正确性、无卡/无概率/无词频三种缺失组合、db 版本可在写事务内复用。
- **策略层**：每个策略的纯函数边界（概率 0/0.5/1、band 1/25/nil、到期/未到期）。
- **注册层**：`CaseIterable` 全覆盖（id 都有实现）。
- **集成**：`StudySystem` 在 `sm2` 下产出与旧实现逐字段一致；`randomPick` 在 `criticalWords` 下选中集合落在临界区间。
