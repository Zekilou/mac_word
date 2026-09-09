# 可插拔调度层 Implementation Plan（总览）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 本计划拆成多个文件，**一个 Task 一个文件**，逐个执行。

**Goal:** 把「选什么词 / 隔多久再考」从硬编码规则抽成可插拔策略，让策略统一消费 BKT 概率 + 词频带 + 事件流 + 到期状态。

**Architecture:** 三层——特征层 `WordFeatures`（一次查全，策略共享）；决策层 `WordScoringStrategy`（选词打分）+ `ReviewIntervalPolicy`（排期算间隔），两者都是**纯函数、不碰数据库**；注册层 `SchedulingRegistry` + 设置项（id → 实现）。默认值保持现有行为，升级不改手感。

**Tech Stack:** Swift 6 / GRDB / SwiftPM / XCTest。

**设计依据：** `docs/superpowers/specs/2026-09-09-scheduling-strategies-design.md`

**规范（项目铁律）：**
- TDD：先写失败测试 → 实现 → 全绿。文件 ≤ 300 行。
- 测试只覆盖纯逻辑与 ViewModel（SwiftUI View 不写测试）。
- 运行测试跳过真实模型类：`swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests`。
- `AppTypes.swift` 是合同文件：**只追加到末尾**。
- 业务代码禁止手写 SQL，必须走 `GraphQueries` 命名方法；System 内用 **`db:` 版本**（复用外层事务）。

---

## Task 索引

| # | 文件 | 内容 | 依赖 |
|---|---|---|---|
| 1 | [task-01-word-features.md](./task-01-word-features.md) | 特征层：`WordFeatures` + `GraphQueries+Features` | — |
| 2 | [task-02-protocols-and-registry.md](./task-02-protocols-and-registry.md) | 协议 + 枚举 + `SchedulingRegistry` | 1 |
| 3 | [task-03-scoring-strategies.md](./task-03-scoring-strategies.md) | 三个选词策略 + `WordSelector` | 2 |
| 4 | [task-04-wire-random-pick.md](./task-04-wire-random-pick.md) | 接入造文选词 + 选词器 UI + 设置项 | 3 |
| 5 | [task-05-review-policy-sm2.md](./task-05-review-policy-sm2.md) | `SM2IntervalPolicy`（逐字复刻现有公式） | 2 |
| 6 | [task-06-review-policy-frequency.md](./task-06-review-policy-frequency.md) | `FrequencyAwareIntervalPolicy` + `SchedulingRegistry.reviewPolicy` | 5 |
| 7 | [task-07-wire-study-system.md](./task-07-wire-study-system.md) | `StudySystem` 接入 + 设置页 | 5, 6 |
| 8 | [task-08-regression-and-memo.md](./task-08-regression-and-memo.md) | 回归 + 备忘录归档 | 1–7 |

---

## 代码文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/WordRecitingApp/Scheduling/WordFeatures.swift` | 新建 | 特征值类型（词频 + 概率 + 事件 + 卡片） |
| `Sources/WordRecitingApp/ECS/GraphQueries+Features.swift` | 新建 | 批量特征查询（一次 SQL） |
| `Sources/WordRecitingApp/Scheduling/SchedulingStrategy.swift` | 新建 | `ScoringContext` + 两个协议 |
| `Sources/WordRecitingApp/Scheduling/SchedulingRegistry.swift` | 新建 | id → 实现 |
| `Sources/WordRecitingApp/Scheduling/Strategies/RandomScoring.swift` | 新建 | 随机打分（复刻旧行为） |
| `Sources/WordRecitingApp/Scheduling/Strategies/CriticalWordScoring.swift` | 新建 | 临界词优先 |
| `Sources/WordRecitingApp/Scheduling/Strategies/FrequencyTierScoring.swift` | 新建 | 词频分层 |
| `Sources/WordRecitingApp/Scheduling/WordSelector.swift` | 新建 | top-N / 阈值取词（纯函数） |
| `Sources/WordRecitingApp/Scheduling/Strategies/SM2IntervalPolicy.swift` | 新建 | SM-2（复刻现有公式） |
| `Sources/WordRecitingApp/Scheduling/Strategies/FrequencyAwareIntervalPolicy.swift` | 新建 | SM-2 + 词频/概率调制 |
| `Sources/WordRecitingApp/AppTypes.swift` | 修改 | `SchedulerID` 追加 `.sm2Frequency`；新增 `WordScoringID` |
| `Sources/WordRecitingApp/Settings/AppSettings.swift` | 修改 | `wordScoringID` |
| `Sources/WordRecitingApp/UI/Creation/GenerateViewModel.swift` | 修改 | `randomPick` 走策略 |
| `Sources/WordRecitingApp/UI/Creation/GenerateView+PickerColumn.swift` | 修改 | 策略下拉 |
| `Sources/WordRecitingApp/ECS/Systems/StudySystem.swift` | 修改 | 调 `ReviewIntervalPolicy` |
| `Sources/WordRecitingApp/UI/StudyViewModel.swift` | 修改 | `StudyOp` 传 `policyID` |
| `Sources/WordRecitingApp/Settings/GeneralSettingsView.swift` | 修改 | 选词策略下拉 |

测试目录根：`Tests/WordRecitingAppTests`。

---

## 验收标准

- `swift build` 0 warning、0 error。
- 全量测试（跳过真实模型类）全绿，基线 745 项无回归。
- 默认行为不变：`schedulerID == .sm2` + `wordScoringID == .random` 时，复习间隔与选词结果与升级前一致。
- 新增测试覆盖：特征查询（含三种缺失组合 + db 版本）、每个策略的纯函数边界、注册表全 `allCases` 覆盖、`randomPick` 接入、`StudySystem` 接入。
- 每个 Task 一条独立 commit。

---

## Self-Review

- **Spec coverage**：spec §4 特征层 → Task 1；§5.1 选词 → Task 2/3/4；§5.2 排期 → Task 2/5/6/7；§5.3 枚举与注册 → Task 2；§6 接入点 → Task 4/7；§7 S1–S3 → Task 1–7；§9 测试策略 → 各 Task Step 1。
- **Placeholder scan**：无 TBD / TODO；所有代码块为完整可编译片段。
- **Type consistency**：`WordFeatures` / `CardSchedule` 在 Task 1 定义，Task 3/5/6 引用；`ScoringContext` / `WordScoringStrategy` / `ReviewIntervalPolicy` / `SchedulingRegistry` 在 Task 2 定义，Task 3–7 引用；`WordScoringID` 在 Task 2 定义，Task 3/4 引用；`SchedulerID.sm2Frequency` 在 Task 2 定义，Task 6/7 引用。

## Execution Handoff

建议 **Subagent-Driven**：每个 Task 文件独立派给一个 sub-agent，主 agent 只做验收（跑测试 + 检查文件行数 ≤ 300）。也可以 Inline 顺序执行。
