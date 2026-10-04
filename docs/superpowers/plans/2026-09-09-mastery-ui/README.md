# 词汇量准确建模 · 前端改造计划（概率主口径）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 本计划拆成多个文件，**一个 Task 一个文件**，逐个执行。
>
> **前一版计划已作废并删除**：那一版只是在现有 UI 上「贴」概率徽章和新区块，属于叠加，不是改造。本版是**改现有页面**。

**Goal:** 把前端的**判定口径从「用户显式标记的 mastery 0/1/2」换成「BKT 后验概率」**——同一个 `WordMarkState`，判定与配色改由概率驱动；词表、阅读词块、卡片浏览、词典、分析页、复习页全部按新口径改造，旧口径只在模型还没数据时兜底。

**前置依赖（已完成）：** 阶段二 `docs/superpowers/plans/2026-09-09-mastery-bkt-modeling/` task-01~07 已落地（`comp_mastery_belief`、`BKTModel`、`MasterySystem`、真实 `word_families.json`、`GraphQueries+Mastery`）。

**Architecture:** 一个核心类型 + 六个消费页——
- `WordMarkState` 是**全应用唯一的词块状态判定**（词表 / 初始化 / RSS / 生成文章 / 卡片浏览 / 词典都走它）。改它一处，六个页面的判定同时切换。
- 各页 ViewModel 各自把 `belief` 喂进来（来源统一是 `GraphQueries.allMasteryBeliefs()` / `RecordedLemma.belief` / `CardListItem.belief`）。
- 文案 / 档位 / 阈值放纯函数，View 只负责画。

**Tech Stack:** SwiftUI / Observation / XCTest。

**规范（项目铁律）：**
- TDD：先写失败测试 → 实现 → 全绿。文件 ≤ 300 行。
- 测试只覆盖 ViewModel 与纯逻辑（SwiftUI View 不写测试）。
- 运行测试跳过真实模型类：`swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests`。
- 不新增并行口径：**全应用只有 `WordMarkState` 一处判定**，禁止各页自己写 if。

---

## 现有页面衡量（逐页审计）

| # | 页面 / 组件 | 现状展示 | 与新口径的冲突 | 改法 | Task |
|---|---|---|---|---|---|
| 1 | `WordMarkState`（判定核心） | `from(mastery:seenCount:)`：mastery≥1.999 会 / ≤1.001 不会 / 中间「学习中 1.5」；颜色按 1~2 渐变 | 完全不看概率；`.learning` 携带的是 1~2 而非概率 | 新增 `from(belief:mastery:seenCount:)` 概率优先；`.learning` 改携带概率 0~1；标签改百分比；旧函数降级为兜底 | 1 |
| 2 | 词表页 | 状态圆点 + 状态标签 + `mastery 0.0~2.0` 裸数值 + 「阅读频次 N 次」 | 裸数值是旧口径；「阅读频次」≠ 上下文多样性 | 去掉裸 mastery 数值；判定走概率；频次改为「上下文多样性（region 数）+ 事件数」；排序/筛选按概率档位 | 2 |
| 3 | 初始化词块 / RSS 词块 / 生成文章词块 | 三处各有一份 `helpText(for:)`，文案在讲「已会/不会/学习中」的 0/1/2 语义 | 判定不看概率；文案与模型脱节 | 三处统一传 `belief`；helpText 改概率文案（含「不是精确测量」） | 3 |
| 4 | 卡片浏览页 | `masteryBadge` 显示「会/不会/学习中」胶囊，无概率 | 无概率 | 徽章改概率百分比 + 档位色 | 4 |
| 5 | 词典面板 | 「标为会」按钮 + 状态色，无模型信息 | 无概率 / 词频 / 事件 | 概率徽章 + 词频带 + 最近事件时间线；按钮文案随状态 | 4 |
| 6 | 分析页 | 「词汇能力」四卡：已会 / 不会 / 出现过 / 未标记（全部基于 mastery 极值） | 四卡是旧口径；没有词频坐标维度 | 四卡改为**概率档位分布** + **词频带画像 + 词汇量估算**（含阈值参照与免责说明） | 5 |
| 7 | 复习页 | 卡片正面词 / 背面释义；队列按 `mastery ≥ 1.999` 排除「已会」 | 背面无模型信息；队列排除口径是旧的 | 背面加概率 / 词频带 / 事件摘要；队列排除改「显式标记会 **或** 模型高置信」 | 6 |

> 说明：审计覆盖了导航壳里所有会出现词汇状态的地方（`WordMarkState` 的全部调用点，共 6 个页面 + 1 个判定核心 + 1 个队列 SQL）。

---

## Task 索引

| # | 文件 | 内容 | 依赖 |
|---|---|---|---|
| 1 | [task-01-probability-first-state.md](./task-01-probability-first-state.md) | `WordMarkState` 概率主口径 + 展示纯函数 + `CardListItem.belief` | — |
| 2 | [task-02-vocabulary-list.md](./task-02-vocabulary-list.md) | 词表页改造（首个消费方） | 1 |
| 3 | [task-03-reading-blocks.md](./task-03-reading-blocks.md) | 初始化 / RSS / 生成文章 三处词块改造 | 1 |
| 4 | [task-04-card-browser-dictionary.md](./task-04-card-browser-dictionary.md) | 卡片浏览 + 词典改造 | 1 |
| 5 | [task-05-analytics.md](./task-05-analytics.md) | 分析页改造（概率分布 + 词频带画像） | 1 |
| 6 | [task-06-study.md](./task-06-study.md) | 复习页改造（队列判定 + 卡片背面） | 1 |
| 7 | [task-07-regression-and-memo.md](./task-07-regression-and-memo.md) | 回归 + 冒烟 + 归档 | 1–6 |

---

## 关键设计决定

### 0. 颜色只表档位，不表连续量（P0）

旧实现用 `hue 0→120` 把 mastery 1→2 映射成连续色，导致「1.001 不会」和「1.4 学习中」视觉上都是红。改为：

| 档位 | 颜色 | 连续量怎么表达 |
|---|---|---|
| 会（概率 ≥ 0.85） | 绿 | 概率数字 |
| 学习中（0.20 < 概率 < 0.85） | 琥珀（单一色，不再渐变） | 概率数字 |
| 不会（概率 ≤ 0.20） | 红 | 概率数字 |

**来源用图标区分，不占颜色通道**：显式标记 = `hand.tap`，模型推断 = `waveform.path.ecg`，被动 seen = `eye`。

### 1. 概率优先，显式标记兜底

```
有 BKT 后验概率 → 按概率档位判定（≥0.85 会 / ≤0.20 不会 / 中间学习中）
没有概率       → 回退到用户显式标记（mastery 0/1/2），再回退到 seen / 无记录
```

理由：模型是「准确建模」的主口径；用户显式标记仍然有价值（尤其模型数据不足时），但不能覆盖模型的持续推断。

### 2. `.learning` 的语义变了（1~2 → 0~1）

`WordMarkState.learning(Double)` 的载荷从「mastery 1~2」改为「概率 0~1」。
- 颜色公式不变（`hue = t * 120/360`），但现在 `t` 就是概率，语义自洽。
- 标签从「学习中 1.5」变成「学习中 50%」。
- **会破坏既有断言**：`WordMarkState.from(mastery: 1.5, ...) == .learning(1.5)` 现在应为 `.learning(0.5)`。相关测试按 Task 1 更新。

### 3. 阈值集中、可调

```swift
static let knownThreshold = 0.85
static let unknownThreshold = 0.20
```

放在 `WordMarkState` 上，禁止各页散落魔法数字。

### 4. 频次 ≠ 多样性

旧词表页的「阅读频次 N 次」只是 `seen_count`（累计出现次数）。CD 研究（Meta-analysis d=0.44）指出**上下文多样性**比频次更能预测学习，所以改为展示「N 个上下文 · M 次事件」，数据来自 `comp_word_event`。

### 5. 诚实标注

所有概率文案必须带「模型估计 / 不是精确测量」；分析页必须有「含未观测词先验外推」「词频只作参考坐标」的免责说明。

---

## 验收标准

- `swift build` 0 warning、0 error。
- 全量测试全绿；`WordMarkState` 判定相关的既有测试按新语义更新。
- 六个页面的词块状态**全部**由概率驱动（`grep WordMarkState.from` 不再出现只看 mastery 的调用点）。
- 无概率数据时全应用正常降级（不崩、显示旧口径或 `—`）。
- 每个 Task 一条独立 commit。

---

## Self-Review

- **Spec coverage**：审计表 7 行 ↔ 7 个 Task 一一对应。
- **Placeholder scan**：无 TBD / TODO；所有代码块为完整可编译片段。
- **Type consistency**：`WordMarkState.from(belief:mastery:seenCount:)` 与 `knownThreshold` / `unknownThreshold` 在 Task 1 定义，Task 2–6 全部引用；`MasteryPresentation.percentText/levelIndex/levelLabel/helpText` 在 Task 1 定义，Task 2–6 引用；`CardListItem.belief` 在 Task 1 定义，Task 4/6 引用。

## Execution Handoff

建议 **Subagent-Driven**：每个 Task 文件独立派给一个 sub-agent，主 agent 只做验收（跑测试 + 检查文件行数 ≤ 300）。也可以 Inline 顺序执行。
