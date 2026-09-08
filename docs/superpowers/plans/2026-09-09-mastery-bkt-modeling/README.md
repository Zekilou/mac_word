# 词汇量准确建模 · 阶段二：词频坐标落地 + BKT 概率化掌握度 —— 实施计划（总览）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 本计划拆成多个文件，**一个 Task 一个文件**，逐个执行。执行顺序见下方「Task 索引」。

**Goal:** 把 `mastery` 从静态的 0/1/2 标量升级为**有研究依据的概率化后验**——先用 BNC/COCA 词族表把词频坐标真正落地（阶段一遗留），再用 BKT（Bayesian Knowledge Tracing）把「标记 / 做题 / 查词 / 被动看到」的全部事件流重放成 `P(用户会这个词)`。

**Architecture:** 事件流（阶段一已落 `comp_word_event`）是**唯一事实来源**；`MasterySystem` 按时间升序**重放**一个 Lemma 的全部事件，用 BKT 前向更新得到后验概率，写入新组件 `comp_mastery_belief`。事件种类通过**发射矩阵**统一进同一个贝叶斯更新（`seen` 不提供观察信息，只提供学习机会）；`trust` 控制证据强度（0 = 无信息）；词频带提供初始先验 `P(L0)`；上下文多样性（不同 region 数）调节学习率 `P(T)`。重放是幂等的，参数版本变更后可全量重算。

**Tech Stack:** Swift 6 / GRDB / SwiftPM / XCTest。

**规范（项目铁律）：**
- TDD：先写失败测试 → 实现 → 全绿。文件 ≤ 300 行（超限拆文件）。
- 测试只用内存库 + 内联夹具，**禁止真实模型推理测试**。
- 运行测试时跳过真实模型测试类：`swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests`。
- `AppTypes.swift` 是 AI 合同文件：**不得改 case 顺序、不得改 rawValue、不得删除 case；新增 case 只能追加到末尾**。
- 新增组件必须同步登记 `EntityRegistry.tableNameMap`。
- 业务代码禁止手写 SQL，必须走 `GraphQueries` 的命名方法；System 内要用 **`db:` 版本**（复用外层事务，不另开读写事务）。

---

## Task 索引

| # | 文件 | 内容 | 依赖 |
|---|---|---|---|
| 1 | [task-01-word-family-resource.md](./task-01-word-family-resource.md) | 生成并登记真实 `word_families.json`（BNC/COCA 词族表） | — |
| 2 | [task-02-mastery-belief-schema.md](./task-02-mastery-belief-schema.md) | 迁移 v5：`comp_mastery_belief` + 组件 + 注册表 | — |
| 3 | [task-03-bkt-model.md](./task-03-bkt-model.md) | `BKTModel` 纯算法（发射矩阵 / 先验 / 学习率 / 重放） | — |
| 4 | [task-04-graph-queries-db-versions.md](./task-04-graph-queries-db-versions.md) | `GraphQueries+Region` 补 `db:` 版本 | 1, 2 |
| 5 | [task-05-mastery-system.md](./task-05-mastery-system.md) | `MasterySystem`：重放事件流算后验 | 2, 3, 4 |
| 6 | [task-06-wire-mastery-updates.md](./task-06-wire-mastery-updates.md) | `RegionRecorder` 自动更新 + 启动全量回填 | 5 |
| 7 | [task-07-belief-query-and-display.md](./task-07-belief-query-and-display.md) | 查询 API + 词表列表展示掌握度概率 | 5 |
| 8 | [task-08-regression-and-memo.md](./task-08-regression-and-memo.md) | 全量回归 + 备忘录归档 | 1–7 |

---

## BKT 设计说明（为什么这么做）

### 1. 四参数 BKT → 发射矩阵

经典 BKT（Corbett & Anderson, 1995）四参数：`P(L0)` 初始会、`P(T)` 学会、`P(G)` 猜对、`P(S)` 失误，只处理「答对/答错」二元观察。

本项目有 6 种事件（`seen` / `lookup` / `markKnown` / `markUnknown` / `quizCorrect` / `quizWrong`），所以把 guess/slip 推广成**每种事件一个发射模型**：

```
P(会 | 观察到事件 e) = P(会)·P(e|会) / [ P(会)·P(e|会) + P(不会)·P(e|不会) ]
```

| 事件 | P(e \| 会) | P(e \| 不会) | 直觉 |
|---|---|---|---|
| `quizCorrect` | 0.90 | 0.15 | 答对是强证据 |
| `quizWrong` | 0.10 | 0.85 | 答错是强证据 |
| `markKnown` | 0.95 | 0.10 | 用户自陈「会」最强 |
| `markUnknown` | 0.08 | 0.92 | 用户自陈「不会」最强 |
| `lookup` | 0.20 | 0.70 | 查词 = 大概率不认识 |
| `seen` | 0.50 | 0.50 | **被动看到：无观察信息** |

### 2. 为什么 `seen` 是 0.5/0.5

被动词表出现**不代表**用户会或不会。但它确实是**一次学习机会**——所以它不更新后验（后验 = 先验），但**仍然触发学习转移 `P(T)`**。这正是 Contextual Diversity 研究（Meta-analysis d=0.44, p<.001）的落点：决定词汇学习的是**接触的上下文多样性**，不是单纯的频次计数。

### 3. trust 控制证据强度

`trust` 是阶段一已经落库的事件级可信度（主动 1.0 / 被动 0.0）。本阶段把它变成**证据强度**：

```
P_eff(e|·) = 0.5 + (P(e|·) - 0.5) · trust
```

- `trust = 1` → 完全按发射矩阵更新（主动交互）。
- `trust = 0` → `P_eff = 0.5/0.5` → 后验不变（无信息），但学习转移照常发生。

### 4. 词频带 → 先验 `P(L0)`

`band 1..25` 线性映射到 `0.90..0.10`；无词频坐标（表外词）用保守先验 `0.30`。

> ⚠️ **诚实标注**：BKT 框架本身（Corbett & Anderson 1995）与「CD 影响学习」有文献支撑；**具体参数值与 `band → P(L0)` 的映射形状是启发式默认值，尚未在真实用户数据上拟合**。所有参数集中在 `BKTParameters`，带 `version` 字段写入库；阶段三用事件日志做 EM/MLE 拟合后，只需改版本号并全量重算。

### 5. 重放而非增量

每次事件后**重放该词全部事件**（时间升序）得到后验，而不是增量更新。理由：
- **幂等**：参数变更 / 修 bug 后可无条件重算，不会累积漂移。
- **可验证**：测试可以直接构造事件序列断言最终概率。
- 成本可控：单词语料量级很小（一个词的事件数通常是几十），配 `(lemma_id, occurred_at)` 索引后是索引扫描。

### 6. 与 `comp_user_known.mastery` 的关系

**不替换**。`mastery`（0/1/2）仍是用户显式标记的、UI 与既有测试依赖的标量；`comp_mastery_belief.belief` 是模型的后验概率。两者并存，后续阶段再讨论如何合并展示。

---

## 代码文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/WordRecitingApp/Resources/word_families.json` | 新建（脚本生成） | 内置词频族表 |
| `scripts/build_word_families.py` | 修改 | 支持单文件 / 按带分目录两种输入 |
| `Package.swift` | 修改 | 登记 `word_families.json` 资源 |
| `Sources/WordRecitingApp/AppTypes.swift` | 修改 | 追加 `ComponentID.masteryBelief` |
| `Sources/WordRecitingApp/Data/Migrations.swift` | 修改 | 注册 `v5_mastery_belief` |
| `Sources/WordRecitingApp/ECS/MasteryComponents.swift` | 新建 | `MasteryBeliefComponent` |
| `Sources/WordRecitingApp/ECS/EntityRegistry.swift` | 修改 | `tableNameMap` 追加 1 项 |
| `Sources/WordRecitingApp/Mastery/BKTModel.swift` | 新建 | 纯函数 BKT（参数 / 发射 / 先验 / 学习率 / 重放） |
| `Sources/WordRecitingApp/ECS/GraphQueries+Region.swift` | 修改 | 补 `db:` 版本查询 |
| `Sources/WordRecitingApp/ECS/Systems/MasterySystem.swift` | 新建 | 重放事件流 → 后验落库 |
| `Sources/WordRecitingApp/ECS/RegionRecorder.swift` | 修改 | 记完事件自动更新后验 |
| `Sources/WordRecitingApp/ECS/VocabularyMaintenance.swift` | 修改 | 启动全量回填后验 |
| `Sources/WordRecitingApp/ECS/GraphQueries+Vocabulary.swift` | 修改 | `RecordedLemma` 增加 `belief` |
| `Sources/WordRecitingApp/UI/Init/VocabularyListView.swift` | 修改 | 列表展示掌握度概率 |

测试目录根：`Tests/WordRecitingAppTests`。

---

## 验收标准

- `swift build` 0 warning、0 error。
- 全量测试（跳过真实模型类）全绿，阶段一基线 565 项无回归。
- `WordFrequency.bundled != nil`（真实词表已登记），词频回填在生产中真正生效。
- 新增测试覆盖：资源校验、迁移/级联、组件 round-trip、BKT 算法各分支、`db:` 版本查询、`MasterySystem` 重放、自动更新、回填、查询与展示。
- 每个 Task 一条独立 commit。

---

## Self-Review

- **Spec coverage**：阶段二选定范围「词表资源 + BKT」→ Task 1 落地词频坐标；Task 2–7 落地 BKT 概率化掌握度（含 trust 加权、CD 调节、词频先验、幂等重放、UI 展示）。
- **Placeholder scan**：无 TBD / TODO；所有代码块为完整可编译片段。
- **Type consistency**：`MasteryBeliefComponent`（`belief` / `opportunities` / `lastEventAt` / `updatedAt` / `paramsVersion`）在 Task 2 定义，Task 5/7 引用一致；`BKTParameters` / `BKTModel` / `MasteryOp` 在 Task 3/5 定义，Task 6 引用一致；`GraphQueries.wordEvents(_:lemmaId:ascending:limit:)` 的 `db:` 版本在 Task 4 定义，Task 5 引用一致。

## Execution Handoff

建议 **Subagent-Driven**：每个 Task 文件独立派给一个 sub-agent，主 agent 只做验收（跑测试 + 检查文件行数 ≤ 300）。也可以 Inline 顺序执行。
