# 词汇量准确建模 · 阶段一：数据基础 —— 实施计划（总览）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 本计划拆成多个文件，**一个 Task 一个文件**，逐个执行。执行顺序见下方「Task 索引」。

**Goal:** 为「给用户的词汇量做准确建模」补齐数据地基——把每一次词汇接触（主动标记 / 做题 / 查词 / 被动看到）作为**带上下文与可信度的全量事件**落库，并给每个词元挂上**词频族坐标**，使后续的概率化掌握度（BKT）、全局遗忘（FSRS）、上下文多样性（CD）、接受/产出（Nation）都有数据可依。

**Architecture:** 沿用现有 ECS。新增 `Region` 节点（一次「显示词汇的上下文」，页面/会话级）与 `WordEvent` 事件节点（单次词事件），事件通过 `produces`（lemma→event）与 `contains`（region→event）两条边接入图；事件与 region 各自带 `trust` 可信度。新增 `LemmaFrequency` 组件挂 Lemma，数据来自内置精简词频族表（BNC/COCA 词族带）。所有写入走 `World.run(System)`，业务代码不手写 SQL。

**Tech Stack:** Swift 5.9+ / GRDB / SwiftPM / XCTest。

**规范（项目铁律）：**
- TDD：先写失败测试 → 实现 → 全绿。文件 ≤ 300 行（超限拆文件）。
- 测试只用内存库 + 内联夹具，**禁止真实模型推理测试**。
- 运行测试时跳过真实模型测试类：`swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests`。
- `AppTypes.swift` 是 AI 合同文件：**不得改 case 顺序、不得改 rawValue、不得删除 case；新增 case 只能追加到末尾**。
- 新增组件必须同步登记 `EntityRegistry.tableNameMap`，否则 `EntityRegistryTests.testTableNameMapCoversAllComponentIDs` 失败。

---

## Task 索引

| # | 文件 | 内容 | 依赖 |
|---|---|---|---|
| 1 | [task-01-apptypes-contract.md](./task-01-apptypes-contract.md) | 合同扩展：`NodeKind.region`、`ComponentID.region/wordEvent/lemmaFrequency`、`RegionKind`、`WordEventKind` | — |
| 2 | [task-02-migration-v4.md](./task-02-migration-v4.md) | 迁移 v4：`comp_region` / `comp_word_event` / `comp_lemma_frequency` + 索引 | 1 |
| 3 | [task-03-components-registry.md](./task-03-components-registry.md) | 三个组件结构体 + `tableNameMap` 登记 | 2 |
| 4 | [task-04-region-system.md](./task-04-region-system.md) | `RegionSystem`：region 幂等 upsert + 全量词事件落库 + 两条边 | 3 |
| 5 | [task-05-word-frequency-provider.md](./task-05-word-frequency-provider.md) | 词频坐标：`WordFrequencyProvider` + 内置资源 + 构建脚本 | 1 |
| 6 | [task-06-lemma-frequency-system.md](./task-06-lemma-frequency-system.md) | `LemmaFrequencySystem`：增量打标 + 全量回填 | 5 |
| 7 | [task-07-graph-queries-region.md](./task-07-graph-queries-region.md) | 查询 API：`GraphQueries+Region` | 4, 6 |
| 8 | [task-08-wire-touch-points.md](./task-08-wire-touch-points.md) | 6 个接入点写入事件（5 主动 + 1 被动） | 4 |
| 9 | [task-09-backfill-and-memo.md](./task-09-backfill-and-memo.md) | 启动回填 + 备忘录归档 | 6, 8 |

---

## 设计要点（为什么这么做）

### 1. Region = 「一次显示词汇的上下文」

用户原话：「所有显示词汇的地方都是一个 region，region 中出现的记录附上 region 信息」。

- Region 是**页面/会话级**的，不是词级的。一次「打开某篇文章」「复习某张卡」「查一次词典」= 一个 region。
- Region 的 id 必须**稳定可复用**（同一上下文重复打开复用同一 region），因此由调用方按业务键构造，例如 `region-study-<cardId>`、`region-rss-<itemId>`、`region-dictionary`。
- 量级问题（「所有词出现的历史具体位置这个量级的数据怎么存」）用**事件流**解决：region 只存一份元信息，每个词事件存一行 `comp_word_event`（含 `lemma_id` / `region_id` / `event_kind` / `trust` / `occurred_at`），配 `(lemma_id, occurred_at)` 与 `(region_id)` 两个索引，查询是索引扫描，不是全表扫。

### 2. 可信度分层（trust）

| 上下文 | region 基础 trust | 说明 |
|---|---|---|
| `study`（复习卡片） | 1.0 | 用户主动做题 |
| `dictionary`（词典查词） | 1.0 | 用户主动查词 |
| `init`（词汇初始化会话） | 1.0 | 用户主动标记 |
| `rss`（RSS 文章） | 0.0 | 被动看到 |
| `generate`（生成文章） | 0.0 | 被动看到 |

**主动交互在被动 region 内可以覆盖为高可信**：事件级 `trust` 字段 = `override ?? region.trust`。例如在 RSS 文章里主动点「不会」，该事件 trust = 1.0，而同一文章里自动 `seen` 的事件 trust = 0.0。这样后续建模可以按可信度加权，而不是把「刷到过一次」和「亲手标记过」当同一份证据。

### 3. 事件种类有限（用户已确认）

「其实可以记录所有事件，因为对于一个词来说，其事件可能性种类并不多」→ `WordEventKind` 六种：`seen` / `lookup` / `markKnown` / `markUnknown` / `quizCorrect` / `quizWrong`。

### 4. 词频坐标系

用内置精简词频族表（BNC/COCA 词族带 1k~25k）给每个 Lemma 打 `band` + `rank`。**注意**：词频带只是**参考坐标**，不是硬阈值——书面 95% 覆盖约 4,000 词族 / 98% 约 8,000–9,000 词族，口语 95% 约 3,000 / 98% 约 6,000–7,000；Kremmel & Schmitt (2023) 的复制研究指出 98% 阈值并非对所有人都可靠。所以本阶段只做「坐标」，不做「判定」。

---

## 代码文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/WordRecitingApp/AppTypes.swift` | 修改 | 追加枚举 case 与两个新枚举（**只能追加到末尾**） |
| `Sources/WordRecitingApp/Data/Migrations.swift` | 修改 | 注册 `v4_region_and_word_event` |
| `Sources/WordRecitingApp/ECS/RegionComponents.swift` | 新建 | `RegionComponent` / `WordEventComponent` / `LemmaFrequencyComponent` |
| `Sources/WordRecitingApp/ECS/EntityRegistry.swift` | 修改 | `tableNameMap` 追加 3 项 |
| `Sources/WordRecitingApp/ECS/Systems/RegionSystem.swift` | 新建 | region 幂等 + 词事件落库 + 两条边 |
| `Sources/WordRecitingApp/ECS/Systems/LemmaFrequencySystem.swift` | 新建 | 词频打标 |
| `Sources/WordRecitingApp/ECS/GraphQueries+Region.swift` | 新建 | region / 事件 / 词频查询 |
| `Sources/WordRecitingApp/Frequency/WordFrequencyProvider.swift` | 新建 | 协议 + 错误类型 + `WordFrequency` 门面 |
| `Sources/WordRecitingApp/Frequency/BundledWordFrequencyProvider.swift` | 新建 | 加载内置 `word_families.json` |
| `Sources/WordRecitingApp/Resources/word_families.json` | 新建 | 内置精简词频族表（由脚本生成） |
| `Package.swift` | 修改 | 登记新资源 |
| `scripts/build_word_families.py` | 新建 | 词族源文件 → JSON |

测试目录根：`Tests/WordRecitingAppTests`。

---

## 验收标准

- `swift build` 0 warning、0 error。
- 全量测试（跳过真实模型类）全绿，且原有 520 项测试无回归。
- 新增测试覆盖：合同枚举、迁移表/索引/级联、组件 round-trip、`RegionSystem` 幂等与事件计数、词频 Provider、`LemmaFrequencySystem`、查询 API、6 个接入点。
- `git log` 中每个 Task 一条独立 commit。

---

## Self-Review

- **Spec coverage**：5 个数据缺口 → 本阶段覆盖「词频坐标系」（Task 5/6）+「全量事件流 + region + 可信度」（Task 1–4、8），为「概率化掌握度 / 全局遗忘 / CD / 接受产出」提供原始数据（后续阶段）。
- **Placeholder scan**：无 TBD / TODO；所有代码块为完整可编译片段。
- **Type consistency**：`RegionRef.trust` 为 region 基础可信度；事件级 trust 用 `override ?? region.trust`；`WordEventKind` / `RegionKind` rawValue 在 Task 1 定死，后续任务只引用。

## Execution Handoff

建议 **Subagent-Driven**：每个 Task 文件独立派给一个 sub-agent，主 agent 只做验收（跑测试 + 检查文件行数 ≤ 300）。也可以 Inline 顺序执行。
