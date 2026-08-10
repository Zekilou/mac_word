# 阶段一：ECS Graph 骨架 + 内容生成 MVP（改写 + 同义词替换）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个可运行的 macOS app，完成：
1. 跑通 **ECS Graph Runtime**（GraphNode 协议 + 组件表 + EntityRegistry + System/World + GraphQueries CTE）
2. 导入 CSV 词库（通过 ImportSystem 翻译为 nodes/edges/comp_* 事务落库）
3. 快速档改写模式：读 `maps_to` 同义词 edges → `RuleBasedGenerator` 同义词替换 + 保序 → 输出改写结果
4. `ContentGenSystem` 事务落库：ArticleNode + comp_text/comp_generation_meta + highlighted_in/appears_in/aggregates_to edges + comp_edge_span
5. 创作视图改写 Tab：diff 视图显示原词→替换词，生成历史列表可回看，点击高亮 span 可查看对应 lemma

**Architecture:** SwiftUI 5 内容 + AppKit 窗口壳（按 UI 偏好）；GRDB 单数据库池；五层架构（Importer / Data / ECS Graph Runtime / Engine / UI）；**所有写入统一通过 System 事务执行**；图查询通过 `GraphQueries`（CTE 封装）；组件表 `comp_*` 按 spec §3.4。不做背诵和分析，留阶段二、三。

**Tech Stack:** Swift 5.10+, SwiftUI 5, AppKit, GRDB.swift, XCTest, SPM

---

## 目录结构（ECS 重排）

```
WordRecitingApp/
├── Package.swift
├── Sources/WordRecitingApp/
│   ├── AppTypes.swift                 # @ai 合同：EntityID/NodeKind/EdgeRel/ComponentID/Rating/QualityTier 等
│   ├── App/
│   │   └── WordRecitingApp.swift      # @main + AppKit 窗口根（NSVisualEffectView .headerView .behindWindow）
│   ├── Data/
│   │   ├── Database.swift             # GRDB DatabasePool 包装
│   │   └── Migrations.swift           # v0 建表迁移：nodes, edges, comp_*（按 spec §3.4 清单）
│   ├── ECS/
│   │   ├── GraphNode.swift            # protocol GraphNode + 7 个 Entity struct (Lemma/Card/Deck/Sentence/Article/Event/Edge)
│   │   ├── Components/                # 一个文件一个 Component struct，≤300 行
│   │   │   ├── TextComponent.swift
│   │   │   ├── LemmaMetaComponent.swift
│   │   │   ├── DeckMetaComponent.swift
│   │   │   ├── ScheduleStateComponent.swift
│   │   │   ├── ReviewEventComponent.swift
│   │   │   ├── MediaRefsComponent.swift
│   │   │   ├── GenerationMetaComponent.swift
│   │   │   ├── EdgeSpanComponent.swift
│   │   │   ├── EdgeWeightedComponent.swift
│   │   │   ├── EdgePositionComponent.swift
│   │   │   ├── TagSetComponent.swift
│   │   │   ├── OrderComponent.swift
│   │   │   ├── CustomDataComponent.swift
│   │   │   ├── ImportFailureComponent.swift
│   │   │   └── AnalyticsCacheComponent.swift
│   │   ├── EntityRegistry.swift       # 节点/组件 CRUD + 按组件签名 JOIN
│   │   ├── GraphQueries.swift         # 图查询命名方法（WITH RECURSIVE CTE）
│   │   ├── System.swift               # protocol System
│   │   ├── World.swift                # World.run(...) 驱动 + 事务编排
│   │   └── Systems/                   # 每个 System 一个文件
│   │       ├── ImportSystem.swift
│   │       ├── StudySystem.swift      # 阶段一仅空壳占位
│   │       ├── ContentGenSystem.swift
│   │       └── AnalyticsSystem.swift  # 阶段一仅空壳占位
│   ├── Importers/
│   │   ├── WordImporter.swift         # 协议 + ImportBatch/EntitySpec/ComponentSpec 数据结构
│   │   └── CSVImporter.swift          # CSV → ImportBatch
│   ├── ContentGeneration/
│   │   ├── ContentGenerator.swift     # 协议 + GenerationConstraints + GeneratedArticle 结构
│   │   └── RuleBasedGenerator.swift   # 模式 B 同义词替换（读 maps_to edges + source_type 过滤）
│   └── UI/
│       ├── ContentView.swift          # 主左右分栏（NSVisualEffectView 根）
│       └── Creation/
│           ├── CreationView.swift     # 创作视图 Tab 容器（改写先跑通，造文 Tab 留空但可见）
│           └── RewriteView.swift      # 左：源文 + 目标词；右：diff 视图；边栏：生成历史
└── Tests/WordRecitingAppTests/
    ├── _SmokeTests.swift
    ├── AppTypesTests.swift
    ├── DatabaseTests.swift
    ├── MigrationsTests.swift
    ├── ECS/
    │   ├── GraphNodeTests.swift
    │   ├── ComponentsTests.swift
    │   ├── EntityRegistryTests.swift
    │   ├── GraphQueriesTests.swift
    │   ├── WorldTests.swift
    │   └── Systems/
    │       ├── ImportSystemTests.swift
    │       └── ContentGenSystemTests.swift
    ├── Importers/
    │   └── CSVImporterTests.swift
    ├── ContentGeneration/
    │   └── RuleBasedGeneratorTests.swift
    └── UI/                            # 仅做逻辑不依赖 SwiftUI 的 ViewModel 测试（若有）
        └── RewriteViewModelTests.swift
```

**约束重申：**
- 单一职责，≤300 行/文件。
- 所有写入**必须通过 `World.run(system)`**；UI 禁止写 SQL。
- 所有图路径查询**必须通过 `GraphQueries` 命名方法**；禁止在业务代码里手写 `WITH RECURSIVE`。
- 每个 Task 先写测试（TDD 红灯 → 绿灯），再 commit。

---

## Task 1: SPM 脚手架 + GRDB 依赖 + 最小 AppKit 窗口壳

> 交付点：`swift build && swift test` 通过；`swift run` 打开的窗口是 NSVisualEffectView 根 + 透明内容。

**Files:**
- Create: `Package.swift`
- Create: `Sources/WordRecitingApp/App/WordRecitingApp.swift`
- Create: `Tests/WordRecitingAppTests/_SmokeTests.swift`

- [ ] **Step 1: Package.swift**（SPM 清单，macOS v14 起，GRDB 依赖 + test target）

- [ ] **Step 2: WordRecitingApp.swift**（AppKit 根窗口：NSVisualEffectView material=.headerView blending=.behindWindow + NSHostingView 装载 SwiftUI ContentView；Titlebar 透明、隐藏 Titlebar controls 的 FullSizeContentView 配置；按用户 UI 偏好留顶部拖动边距）

- [ ] **Step 3: 冒烟测试**（仅 assert true；确保包结构可编译）

- [ ] **Step 4: `swift build && swift test` 通过**

- [ ] **Step 5: Commit**

---

## Task 2: AppTypes 集中类型合同（扩展含 ECS 相关枚举）

> 交付点：所有 ECS 合同枚举（NodeKind/EdgeRel/ComponentID） + 业务枚举（Rating/SchedulerID/DeckSourceKind/GenerationMode/QualityTier/GenerationConstraints）RawValue 稳定，测试全绿。

**Files:**
- Create: `Sources/WordRecitingApp/AppTypes.swift`
- Create: `Tests/WordRecitingAppTests/AppTypesTests.swift`

- [ ] **Step 1: 写失败测试**（校验每个枚举 RawValue 稳定 + 编解码往返 + GenerationConstraints 默认值）

- [ ] **Step 2: 跑测试验证失败**

- [ ] **Step 3: 写 AppTypes.swift**（`@ai:` 注释标成 AI 合同；EdgeRel case 列表必须与 spec §3.3 完全一致，顺序不可变；ComponentID 为 String 枚举，case 名 = 表名去前缀 `comp_`）

- [ ] **Step 4: 跑测试通过**

- [ ] **Step 5: Commit**

---

## Task 3: GRDB Database 池 + 迁移脚本（nodes/edges/comp_*）

> 交付点：`nodes`、`edges`、**全部 15 张 comp_* 组件表**（按 spec §3.4）DDL 可幂等跑通；外键 CASCADE 正确；索引齐备（edges.src_id/dst_id/rel_type 三列联合、comp_schedule_state.(due_at, scheduler_id) 等）。

**Files:**
- Create: `Sources/WordRecitingApp/Data/Database.swift`
- Create: `Sources/WordRecitingApp/Data/Migrations.swift`
- Create: `Tests/WordRecitingAppTests/DatabaseTests.swift`
- Create: `Tests/WordRecitingAppTests/MigrationsTests.swift`

- [ ] **Step 1: Database 失败测试**（Database.inMemory / Database.file 可创建）

- [ ] **Step 2: Database.swift**（Sendable class；PRAGMA journal_mode=WAL + foreign_keys=ON）

- [ ] **Step 3: Migration 失败测试**（建表后检查 sqlite_master 中每张表存在 + 每个组件表 entity_id 为 PK + edges FK 生效）

- [ ] **Step 4: Migrations.swift**（GRDB migrator 注册 v0_initial：建 nodes(kind 7 值)、edges(src_id FK nodes/dst_id FK nodes/rel_type TEXT) + 15 张 comp_* 表每表 entity_id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE；所有外键 + 索引）

- [ ] **Step 5: `swift test --filter DatabaseTests/MigrationsTests` 通过**

- [ ] **Step 6: Commit**

---

## Task 4: GraphNode 协议 + 7 个 Entity struct + 所有 Component struct

> 交付点：每个 Entity 遵守 GraphNode；每个 Component 对应一张表，FetchableRecord/PersistableRecord 通过；一个最小 insert→select 往返测试全绿。

**Files:**
- Create: `Sources/WordRecitingApp/ECS/GraphNode.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/TextComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/LemmaMetaComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/DeckMetaComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/ScheduleStateComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/ReviewEventComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/MediaRefsComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/GenerationMetaComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/EdgeSpanComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/EdgeWeightedComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/EdgePositionComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/TagSetComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/OrderComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/CustomDataComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/ImportFailureComponent.swift`
- Create: `Sources/WordRecitingApp/ECS/Components/AnalyticsCacheComponent.swift`
- Create: `Tests/WordRecitingAppTests/ECS/GraphNodeTests.swift`
- Create: `Tests/WordRecitingAppTests/ECS/ComponentsTests.swift`

- [ ] **Step 1: GraphNode 失败测试**（LemmaNode/CardNode/... 遵守协议；id/kind/createdAt 可编码可解码；Codable 往返）

- [ ] **Step 2: GraphNode.swift**（EntityID 别名；NodeKind 7 case；protocol GraphNode；7 个空壳 struct：LemmaNode/CardNode/DeckNode/SentenceNode/ArticleNode/EventNode/EdgeNode。Entity struct 自身**不要加字段**；所有真实字段放 Components）

- [ ] **Step 3: Component 失败测试**（针对每个 Component：insert 一行 → select 回 → 字段相等；GRDB 自动列映射；Codable 相等性）

- [ ] **Step 4: 15 个 Component 文件**（每个 struct 仅字段 + `FetchableRecord` + `PersistableRecord`。JSON 字段用 GRDB 的 `DatabaseValueConvertible` + JSONEncoder/Decoder 扩展。每个文件 ≤200 行。）

- [ ] **Step 5: `swift test --filter GraphNodeTests/ComponentsTests` 通过**

- [ ] **Step 6: Commit**

---

## Task 5: EntityRegistry（节点/组件 CRUD + 组件签名 JOIN 过滤）

> 交付点：`EntityRegistry` 提供 `insert(node:components:)` / `fetch(byID:)` / `filter(requiresAll:)`（按组件签名 JOIN 过滤 EntityID 集合）。事务边界清晰。

**Files:**
- Create: `Sources/WordRecitingApp/ECS/EntityRegistry.swift`
- Create: `Tests/WordRecitingAppTests/ECS/EntityRegistryTests.swift`

- [ ] **Step 1: 失败测试**：造 3 个 CardNode，仅 2 个挂 comp_text + comp_schedule_state；`filter(requiresAll: [.text, .schedule_state])` 必须返回 2。

- [ ] **Step 2: EntityRegistry.swift**（Sendable class 持有 Database；内部方法 `insertNode` / `upsertComponent` / `fetchComponents(of: for:)` / `filter(requiresAll:)` 用 INNER JOIN 拼接 SQL）

- [ ] **Step 3: 跑测试通过**

- [ ] **Step 4: Commit**

---

## Task 6: GraphQueries（图查询命名方法集合 + CTE 实现）

> 交付点：3 个命名方法全部实现并带测试：`neighbors(of:rel:)` 1 跳、`contextSubgraph(of:depth:)` 2 跳、`weakLemmas(in:thresholdAgainRatio:)`（通过 produces→review_event 按 again_ratio 聚合到 lemma）。

**Files:**
- Create: `Sources/WordRecitingApp/ECS/GraphQueries.swift`
- Create: `Tests/WordRecitingAppTests/ECS/GraphQueriesTests.swift`

- [ ] **Step 1: 失败测试**（每个方法各一：① Deck→has→Card 1 跳邻居数；② Lemma→appears_in→Sentence→aggregates_to→Article 2 跳子图节点数；③ 构造 5 张卡×20 次复习，其中 3 张卡 again_ratio≥30% → weakLemmas 只返回这 3 张卡对应 Lemma）

- [ ] **Step 2: GraphQueries.swift**（统一用 `WITH RECURSIVE` CTE；超过 5 跳打印 warning）

- [ ] **Step 3: 跑测试通过**

- [ ] **Step 4: Commit**

---

## Task 7: System 协议 + World 容器

> 交付点：`System` 协议 + `World.run(system)` 能把签名匹配的 Entity 集合喂给 System.execute；事务原子；失败回滚。

**Files:**
- Create: `Sources/WordRecitingApp/ECS/System.swift`
- Create: `Sources/WordRecitingApp/ECS/World.swift`
- Create: `Tests/WordRecitingAppTests/ECS/WorldTests.swift`

- [ ] **Step 1: 失败测试**：造一个测试 System，声明 requiresAll=[.text]，向所有匹配节点的 comp_text 追加 " ✓"。跑 World.run 后验证所有被匹配的文本被修改、事务可回滚。

- [ ] **Step 2: System.swift**（`protocol System: Sendable { associatedtype Context; static var requiresAll: [ComponentID] { get }; func execute(world: inout WorldContext, entities: [EntityID], ctx: Context) throws }` + type erasure 辅助，便于 `World.run` 泛型调用）

- [ ] **Step 3: World.swift**（Sendable final class，持有 Database + EntityRegistry + GraphQueries；`run<System>(_ system: System, context: System.Context)` 内部：① 按 requiresAll 过滤 ids → ② 开事务 → ③ 调 system.execute → ④ 提交/回滚）

- [ ] **Step 4: 跑测试通过**

- [ ] **Step 5: Commit**

---

## Task 8: 4 个 System 空壳（占位）+ ImportSystem 基础事务骨架

> 交付点：StudySystem/AnalyticsSystem 空壳（仅实现 requiresAll，execute 空操作）；ImportSystem 能接受一个 ImportBatch 在单事务内写 nodes/components/edges/import_failure events。

**Files:**
- Create: `Sources/WordRecitingApp/ECS/Systems/ImportSystem.swift`
- Create: `Sources/WordRecitingApp/ECS/Systems/StudySystem.swift`
- Create: `Sources/WordRecitingApp/ECS/Systems/ContentGenSystem.swift`（占位，阶段一 Task11 填完）
- Create: `Sources/WordRecitingApp/ECS/Systems/AnalyticsSystem.swift`
- Create: `Tests/WordRecitingAppTests/ECS/Systems/ImportSystemTests.swift`

- [ ] **Step 1: 失败测试**：构造一个含 2 DeckNode + 10 CardNode + 1 failure 的 ImportBatch。`World.run(ImportSystem.import(batch))` 后：nodes 登记薄 13 行；comp_deck_meta 2 行；comp_text 10 行；edges.has 10 行；import_failure 事件 1 行。

- [ ] **Step 2: 各 System 文件**（空壳 Study/Analytics/ContentGen 仅 requiresAll 声明；ImportSystem 完整实现：事务里依次 insert nodes / upsert components / insert edges / write failure events）

- [ ] **Step 3: 跑测试通过**

- [ ] **Step 4: Commit**

---

## Task 9: WordImporter 协议 + CSVImporter（输出 ImportBatch）

> 交付点：CSVImporter 能把 `front,back,lemma,pos` 样例 CSV 翻译成正确的 ImportBatch（LemmaNode→comp_lemma_meta + comp_text，CardNode→comp_text + comp_schedule_state 初始默认，edges.has + edges.instantiates）。

**Files:**
- Create: `Sources/WordRecitingApp/Importers/WordImporter.swift`
- Create: `Sources/WordRecitingApp/Importers/CSVImporter.swift`
- Create: `Tests/WordRecitingAppTests/Importers/CSVImporterTests.swift`

- [ ] **Step 1: 失败测试**：用 5 行 fixture CSV（front/back/lemma/pos 列 + 一行错行）。readNodes 返回的 ImportBatch.componentsByNode 里有 5 LemmaNode + 5 CardNode；edges.spec 里有 5 has（Deck→Card）+ 5 instantiates；failures 有 1 行。

- [ ] **Step 2: WordImporter.swift**（协议 + 数据结构：`ImportBatch`、`EntitySpec(id:kind:)`、`ComponentSpec(componentID:valuesJSON:)`、`EdgeSpec(src:dst:rel:weighted:span:position:)`）

- [ ] **Step 3: CSVImporter.swift**（自动识别分隔符；列识别顺序优先级：lemma/headword/word > pos/词性 > front/正面 > back/背面；未识别列进 comp_custom_data）

- [ ] **Step 4: 跑测试通过**

- [ ] **Step 5: Commit**

---

## Task 10: ContentGenerator 协议 + RuleBasedGenerator（模式 B：同义词替换）

> 交付点：输入源文章 + 目标词列表 → 基于 `maps_to` 同义词 edges（source_type=user/wordnet，weight≥阈值）做词形还原→匹配→替换→恢复屈折；返回 GeneratedArticle（body + spans + 替换详情）。能处理 100 行句子样例，替换准确率 ≥ 95%。

**Files:**
- Create: `Sources/WordRecitingApp/ContentGeneration/ContentGenerator.swift`
- Create: `Sources/WordRecitingApp/ContentGeneration/RuleBasedGenerator.swift`
- Create: `Tests/WordRecitingAppTests/ContentGeneration/RuleBasedGeneratorTests.swift`

**前置：** 规则引擎替换时需要读 maps_to 同义词边——在生成器里以 `graph: GraphQueries` 作为参数传入。RuleBasedGenerator 自己**不直接写数据库**，只输出生成结果；写库由 ContentGenSystem 负责。

- [ ] **Step 1: 失败测试**：造 3 个 LemmaNode(A/B/C) + edges.maps_to(A→B weight=0.9, source_type=user)。目标词=[B]。源文含 A。期望改写结果把 A 替换为 B，且 spans 里替换的 span 的 is_target=true。

- [ ] **Step 2: ContentGenerator.swift**（协议 + GenerationConstraints + GeneratedArticle 结构，含 body、spans[start,end,is_target,lemma_id?,surface_form]、generatorID、tier）

- [ ] **Step 3: RuleBasedGenerator.swift**
  - 步骤：分句 / 词形还原（Lemmatizer：先做一个简单 Porter 2 + 英文字典规则，中文先按分词字符切分或整段保持不切；复杂的留阶段二升级）
  - 对每个 surface_form→lemma_id；若 lemma_id 在 maps_to 有边且目标权重匹配目标词 → 替换为目标表面形式并恢复屈折（English 用简单规则：时态/s 复数/比较级）；中文原样替换
  - 替换结果在 body 上按字符偏移生成 spans，未替换的目标词在文中出现也记 span 但 is_target=true 且 replace_from=nil
  - 同义词优先级：source_type=user > wordnet > cedict，按 weight 降序

- [ ] **Step 4: 跑测试通过**

- [ ] **Step 5: Commit**

---

## Task 11: ContentGenSystem 落库管线

> 交付点：ContentGenSystem 接受 `GeneratedArticle` + 目标词列表 + 源 Article(可选) → 在**单事务**内写：
> - ArticleNode + comp_text(body) + comp_generation_meta(mode/topic/source_text/generator_id/tier/prompt_hash)
> - 每个 span 的 highlighted_in edge（EdgeNode=kind=edge, src=lemma_id, dst=article_id, rel=highlighted_in, comp_edge_span 存 start/end/is_target/surface_form）
> - 若源文存在，写 rewrite_of edge（另需在 §3.3 EdgeRel 里补 `rewrite_of` case — 记 TODO，阶段二 DDL 追加）；先阶段一仅记在 comp_generation_meta.source_text 字段即可，不强行补新 Edge case 避免跑改 AppTypes 合同
> - 每个目标词额外写 comp_edge_weighted 存 weight（规则引擎里 user=1.0，其他按实际）

**Files:**
- Modify: `Sources/WordRecitingApp/ECS/Systems/ContentGenSystem.swift`（Task8 只有空壳）
- Create: `Tests/WordRecitingAppTests/ECS/Systems/ContentGenSystemTests.swift`

- [ ] **Step 1: 失败测试**：调 `World.run(ContentGenSystem.persist(article:targetLemmas:))`；事后 GraphQueries 反查 article_id 的 neighbors(rel: highlighted_in) 得到全部目标词；comp_edge_span 偏移与 body 实际字符串吻合；comp_generation_meta.generator_id == "rule-based"。

- [ ] **Step 2: ContentGenSystem.swift** 完整实现（requiresAll = 接收的是"要生成的目标 lemma 必须存在 comp_text" → requiresAll=[.text]；execute 内部开事务写 3 层）

- [ ] **Step 3: 跑测试通过**

- [ ] **Step 4: Commit**

---

## Task 12: UI - 创作视图改写 Tab + 生成历史 + diff 视图

> 交付点：用户可以跑 UI；在改写 Tab 左侧粘贴源文 + 粘贴目标词列表（用换行/逗号分隔）；点"快速改写"按钮 → 走 World.run(ContentGenSystem.generate(...)) → 右侧视图展示 diff（原词 → 替换词 inline diff）；侧边"生成历史"列表列出最近 20 条 ArticleNode（GraphQueries 查 comp_generation_meta.mode == rewrite + ORDER BY created_at DESC LIMIT 20），点历史卡片正文预览，高亮 span 可 hover 显示对应 headword。

**Files:**
- Create: `Sources/WordRecitingApp/UI/ContentView.swift`（左栏持久导航 + 右内容区 次级 Tab：创作 / 背诵 / 分析；背诵/分析 Tab 先灰显 placeholder）
- Create: `Sources/WordRecitingApp/UI/Creation/CreationView.swift`（TabView：造文 placeholder + 改写）
- Create: `Sources/WordRecitingApp/UI/Creation/RewriteView.swift`（左源文+目标词，右diff，侧边历史）
- Create: `Tests/WordRecitingAppTests/UI/RewriteViewModelTests.swift`（ViewModel 层逻辑测试：把源文解析成 lemma 集合、按钮调用 World.run 的返回拼接正确）

**UI 严格符合用户偏好（来自 memory user_profile.md）：**
- 根层：单 NSVisualEffectView .headerView .behindWindow；右顶部 Edit 按钮（工具栏样式常驻）；左栏 hamburger 可收折；重要按钮在表格/列表首列
- 紧凑 UI；信息密度高垂直显示更多；树节点选中态视觉清晰；变化量显示在每题下方（改写 Tab 里替换详情变化量直接 inline）
- 元素变换动效：跨行 >25px translate，≤25px 直接 snap；长宽直接 snap；仅 translate；容器 mask 裁剪；断点 10px 单向阈值（此阶段先写占位注释，实现在阶段三）

- [ ] **Step 1: RewriteViewModel 失败测试**（ViewModel.parseTargets 能把 "A,B;C\nD" 都识别成 A/B/C/D 四个目标词；ViewModel.runRewrite(source:targets:) 调用 ContentGenSystem 后正确拼装 GeneratedArticle 给 UI）

- [ ] **Step 2: ContentView + CreationView + RewriteView**（View 严格按 UI 偏好；NSHostingView + AppDelegate 确保窗口根配置生效；改写 Tab 用 SwiftUI `AttributedString` 显示 inline diff：原词删除线灰色+新词品牌色高亮；历史列表用 SwiftUI List + ValueObservation 观察 comp_generation_meta 行；点击历史项的 span hover 时显示 "目标词: abandon / 原词: leave / 关系: 用户同义词"）

- [ ] **Step 3: 手动冒烟测试**（`swift run` 打开 app；粘贴一段小英文 + 目标词列表；点击"快速改写"；diff 视图显示；历史列表新增；关重开历史仍在 → 证明落库成功）

- [ ] **Step 4: Commit**

---

## 阶段一退出标准（DOD）

- [ ] `swift build` 零警告通过。
- [ ] `swift test` 全绿（12 个 Task 的所有单元测试都已添加）。
- [ ] 手动冒烟：导入一个 10 行 CSV 词库 + 粘贴 50 词源文 + 3 目标词 → 点改写 → 右侧 diff 视图显示替换 → 关 App → 重开 → 生成历史可见并能回看。
- [ ] 不引入独立图数据库；图查询全部走 GraphQueries + SQLite CTE。
- [ ] 所有写入通过 System；UI 不写 SQL。

阶段一完成后，生成阶段二计划（LocalLLMGenerator 造文 Tab + Anki/CEDICT/Tatoeba 导入器 + FSRS 调度 + 背诵视图）。
