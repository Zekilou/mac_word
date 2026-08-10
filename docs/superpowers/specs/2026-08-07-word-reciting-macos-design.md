# 本地背单词与文章-词关联应用 设计文档

> 日期：2026-08-07
> 状态：待用户复审
> 平台：macOS 原生

## 1. 目标与重心

唯一目的：服务好背单词。

但"服务好背单词"在本项目中的重心不是把卡片翻转做得多炫，而是**让单词在真实文章语境中被习得与复现**。因此工程重心明确为：

- **重心（核心卖点）**：内容生成与文章-词关联层。用户给定目标词列表 + 主题生成文章，或拿现有文章做同义词替换，把目标词植入语境。生成的文章与卡片双向关联，可复习、可分析。
- **基础支撑**：背诵功能保持基础可用——卡片正反面翻转、4 级评分、可插拔调度算法（默认 FSRS）。不在此版本投入额外花活。
- **配套能力**：词库导入（Anki 优先 + 纯文本）、模块化数据分析、严格贴合 Apple HIG 与用户 UI 偏好的应用壳。

实现优先级反映重心：内容生成与文章-词关联优先于背诵花活与高级分析。详见第 10 节。

## 2. 分层架构总览（含 ECS Graph 运行时）

横向五层 + 两个外部边界。模块间通过协议解耦，可插拔点共四个：`Importer`、`Scheduler`、`AnalyticsModule`、`ContentGenerator`。**核心新增一层 ECS Graph Runtime**：所有持久化数据被视为一个"有向多关系图（图节点作为基类）"，通过 Entity/Component/System 组合出全部能力；Repository 模式保留但退化为 EntityRegistry + Component Table 适配层。

| 层 | 职责 | 技术 |
|---|---|---|
| Importer 层 | 统一词库格式入口，每种格式一个插件；通过 ImportSystem 把外部行翻译成 GraphNode + 若干 Component | `WordImporter` 协议 + 注册中心 + ImportSystem（System） |
| GRDB 数据层 | 纯本地 SQLite 持久化；nodes/edges 总登记薄 + comp_* 组件表；图查询通过 GraphQueries（WITH RECURSIVE CTE 封装） | GRDB、ValueObservation 驱动 UI |
| **ECS Graph Runtime**（新增） | `World` 容器 + `EntityRegistry` + 4 个 System（Import/Study/ContentGen/Analytics）+ `GraphQueries` 图查询层。**System 是唯一的行为入口**，按 Component 签名过滤 Entity 集合处理 | 自研（protocol GraphNode + Component struct + System protocol） |
| 核心引擎协议层 | 调度、分析、内容生成三协议，作为各自 System 的内部可插拔实现 | `Scheduler` / `AnalyticsModule` / `ContentGenerator` 协议 |
| 应用壳 + UI | SwiftUI 内容 + AppKit 窗口壳，UI 只和 World/EntityRegistry 交互，永远不直接写 SQL | SwiftUI 5、AppKit、Combine |

关键原则：
- UI 永远不直接写 SQL 或操作 Component 表。写走 `World.run(system)` 或 `EntityRegistry` 命名方法；读走 `EntityRegistry` / `GraphQueries`。
- 四个协议的实现在启动时注册到 DI 容器，然后由对应 System 引用；不使用全局单例。
- Scheduler 协议只输出状态变更（纯函数），I/O 全在 StudySystem 内完成（读 comp_schedule_state → 调 Scheduler.nextState → 写 comp_schedule_state + 新 comp_review_event + edges.produces）。
- ContentGenerator 协议只在实现内部读 GraphQueries（拿词、句、同义子图权重），生成结果通过 `ContentGenSystem` 统一落库成 ArticleNode + 对应 Component + edges.highlighted_in/appears_in/aggregates_to。
- **所有"关系"都走 edges 表 + 边属性 Component**，禁止在 Component 表内用手动外键表达关系（唯一允许的例外：comp_review_event.target_card_id 反查冗余列）。

## 3. 数据模型与 ECS Graph 架构（GRDB SQLite）

设计目标：Anki 导入轻、分析查询快、生成可追溯，并且**底层逻辑架构采用 ECS（Entity-Component-System）把"图节点"作为基类**——整个系统视为一个有向多关系图，图的每个节点（包括边本身）都是 GraphNode Entity，通过挂不同的纯数据 Component 组合出所有能力；行为由 System 按 Component 签名过滤处理。

物理存储仍然是 SQLite 关系表（一个 Component = 一张表，外加 nodes / edges 总登记薄）。启动时由 `EntityRegistry` 把多表按 entity_id 拼装为带组件的完整 Entity；写操作逐 Component 写回各自表。图遍历/3~4 跳邻居查询用 SQLite `WITH RECURSIVE` CTE，不上独立图数据库（数据量未到阈值）。

### 3.1 ECS 决策（已确认的 AAA 组合）

| 维度 | 决策 | 理由 |
|---|---|---|
| 架构模式 | **完整 ECS（Entity × Component × System）**，不是 EC | 4 条主流水线（Import / Study / ContentGen / Analytics）天然对应 4 个 System，行为可组合扩展 |
| 基类写法 | **面向协议** `protocol GraphNode`，所有 Entity struct 显式遵守 | Swift 原生值语义，避免引用语义坑（ARC、可变共享、等号失真） |
| 物理承载 | **逻辑 ECS + SQLite 关系表持久化** | 纯本地、零外部服务；GraphQueries 服务层把常见图模式封装为 CTE 查询 |

### 3.2 GraphNode：图节点基类协议（所有 Entity 都必须实现）

```swift
@ai: 不得改 id / kind 两个属性；新增字段走 Component 机制，不扩展此协议
typealias EntityID = String

enum NodeKind: String, Sendable, Codable {
    case lemma, card, deck, sentence, article, event, edge  // edge 也是 node
}

protocol GraphNode: Identifiable, Sendable, Codable {
    var id: EntityID { get }
    var kind: NodeKind { get }
    var createdAt: Date { get }
}
```

所有具体 Entity（LemmaNode / CardNode / DeckNode / SentenceNode / ArticleNode / EventNode / EdgeNode）都只是带 `kind` 的空壳 struct。实际字段**不在 Entity 上**，而在以 `entity_id` 为外键的 Component 表里。

### 3.3 Entity 注册表（`nodes` 表 + `edges` 表）

| 表 | 关键字段 | 说明 |
|---|---|---|
| `nodes` | id(PK), kind(lemma/card/deck/sentence/article/event/edge), created_at | 所有图节点的总登记薄，保证全局唯一 id |
| `edges` | id(PK, 也是 node_id), src_id(FK nodes), dst_id(FK nodes), rel_type, created_at | 有向边登记薄：**边自身也是 GraphNode（kind=edge）**，因此可以挂 Component 存边属性；`rel_type` 枚举见下方 |

核心 `rel_type`（有向边的语义标签，对应图的 5 种家族）：

```
has                Deck → Card / Deck → Lemma
instantiates       Lemma → Card          （一个词条实例化为多张卡片）
has_state          Card → CardState      （1:1）
produces           Card → ReviewEvent    （复习事件流水 1:N）
appears_in         Lemma → Sentence      （多对多，position 作为 Edge 组件）
translates_to      Sentence → Sentence   （Tatoeba 对齐）
aggregates_to      Sentence → Article    （句子组成文章）
contains           Article → Sentence    （反向）
highlighted_in     Lemma → Article       （经由 Span，这是内容生成主路径）
maps_to            Lemma → Lemma         （同义词/上下位/反义词，source_type 区分 WordNet/CEDICT/user）
owns               Deck → ImportFailure / Deck → CustomSynonymScope
has_media          Lemma/Card → MediaRef
```

`edges` 表**只登记拓扑（谁指向谁、关系类型）**；边权重、位置、rating 等属性不放在 edges 表，而挂到 EdgeNode 的对应 Component 表里（见 3.5 节）。

### 3.4 Components：纯数据组件（一表 = 一个 Component 类型，PK 是 entity_id）

Component 是**无行为纯 struct + FetchableRecord/PersistableRecord**。一张表只存一个职责的数据，绝不跨职责耦合。以下为阶段一、二需要的全部 Component 清单及对应表：

| Component 表 | PK entity_id 关联的 NodeKind | 字段 | 对应能力 |
|---|---|---|---|
| `comp_text` | card, lemma, sentence, article | `text_a`(front/headword/句子正文), `text_b`(back/定义), `language` | 所有文字显示内容 |
| `comp_lemma_meta` | lemma | `pos`, `phonetic_us`, `phonetic_uk`, `senses_json`(CEDICT/WordNet 义项数组) | 词条元数据 |
| `comp_deck_meta` | deck | `name`, `source_kind`, `source_path`, `imported_at` | 词库元数据 |
| `comp_schedule_state` | card | `stability`, `difficulty`, `due_at`, `interval_days`, `reps`, `lapses`, `last_rating`, `last_reviewed_at`, `scheduler_id`, `queue`(new/learning/review), `custom_data_json` | 调度状态，替代原 card_states 单表 |
| `comp_review_event` | event(kind=review) | `target_card_id`, `rated_at`, `rating`, `responded_ms`, `elapsed_days`, `scheduled_interval`, `delta_stability`, `delta_difficulty`, `last_ivl`, `factor` | 替代原 reviews 表；挂在 EventNode 上 |
| `comp_media_refs` | card, lemma | `entries_json`=[{kind,checksum,local_path}] | 替代原 media_refs 单表（JSON 数组避免 1:N 连表查 UI 性能差） |
| `comp_generation_meta` | article, event(kind=gen_run) | `mode`, `topic`, `source_text`, `generator_id`, `quality_tier`, `prompt_hash` | 替代原 generated_articles 的生成元数据 |
| `comp_edge_span` | edge(rel=highlighted_in / appears_in) | `surface_form`, `start`, `end`, `is_target` | 替代原 article_word_spans；作为 highlighted_in / appears_in 边的属性 |
| `comp_edge_weighted` | edge(rel=maps_to / aggregates_to 等) | `weight_double`, `source_type`(user/wordnet/cedict/manual) | 同义词权重、语序权重、同边来源区分；替代原 custom_synonyms 表（custom_synonyms → maps_to 边 + source_type=user） |
| `comp_edge_position` | edge(rel=appears_in) | `position_in_sentence`, `surface_form` | Lemma 在句中的出现位置（辅助 Span 反查） |
| `comp_tag_set` | any node kind | `tags_json` 字符串数组 | 统一 tag 机制：Deck/Card/Lemma/Article 共享 |
| `comp_order` | any 1:N 父-子关系需要排序的 | `sort_index` | Deck → Card 顺序、Article → Sentence 顺序等；替代原 cards.sort_index |
| `comp_custom_data` | any node kind | `payload_json` | 预留"无限扩展孔"：Anki 原字段、未来参数、调度扩展 |
| `comp_import_failure` | event(kind=import_failure) | `deck_id`, `row_index`, `raw_line`, `reason` | 替代原 import_failures 表（改为 EventNode + 此组件） |
| `comp_analytics_cache` | event(kind=analytics_cache) | `module_id`, `scope_hash`, `computed_at`, `payload_json` | 替代原 analytics_cache（改为 EventNode + 此组件） |

**设计原则（强约束）**：
- 任何"实体有了什么就有什么能力"的判断，**永远等价于**"这个 entity_id 在某 Component 表存在一行"。绝不在基类或 Entity struct 上加可选字段。
- 原 spec 里的 decks/cards/card_states/reviews/media_refs/generated_articles/article_word_spans/custom_synonyms/analytics_cache/import_failures **全部消失**，统一改写为 `nodes + edges + 若干 comp_* 表`。建表迁移脚本仍是一次性的。
- 唯一的保留关联：原 `reviews.card_id` 这类"一个复习事件属于哪张卡"的信息现在通过 edges 表表达（`rel=produces, src=card_id, dst=review_event_id`），`comp_review_event.target_card_id` 是冗余反查字段，允许保留以避免三跳。

### 3.5 遗留的"按类表"映射对照表（给 Anki 导入器用）

为了让 Anki Importer 读 `.apkg` 时不用改思路，下面是 Anki 原生 5 表 → 本 ECS Graph 模型的**逐字段映射**，任何导入器严格按此映射：

| Anki 原生 | 对应 GraphNode(s) + Component(s) |
|---|---|
| col | DeckNode + comp_deck_meta |
| notes(mid/guid/tags/flds/sfld/csum) | LemmaNode(s) + comp_text(flds[0]=front, flds[1]=back 等按模板切分) + comp_tag_set |
| cards(nid/did/ivl/factor/reps/lapses/type/queue/due/left/data) | CardNode + comp_schedule_state(ivl→interval_days, factor→difficulty×常数, reps/lapses 直映射, data→custom_data_json) + comp_order(ord) + edges(has: Deck→Card, instantiates: Lemma→Card) |
| revlog(cid/ease/ivl/lastIvl/factor/time/type) | EventNode(kind=review) + comp_review_event + edges(produces: Card→Event) |
| graves | 删除时只删 nodes 登记薄行 + Component 级 ON DELETE CASCADE 即可，不单独建表 |

### 3.6 Systems：行为处理器（消费某个 Component 签名的 Entity 集合）

4 个顶层 System，与 §2 分层里的四个协议一一对应：

| System | 它声明需要的 Component 签名（"我要处理带哪些组件的 Entity"） | 内部调用 |
|---|---|---|
| `ImportSystem` | (DeckNode 或 LemmaNode/CardNode) + comp_deck_meta / comp_text / comp_media_refs | `WordImporter` 协议（CSVImporter、AnkiImporter） |
| `StudySystem` | CardNode + comp_text + comp_schedule_state；产生：EventNode(kind=review) + comp_review_event | `Scheduler` 协议（FSRS 默认、SM-2 备选） |
| `ContentGenSystem` ★ | LemmaNode + comp_text + comp_edge_weighted(同义子图权重) + comp_edge_position + comp_edge_span + SentenceNode/ArticleNode(comp_text/comp_generation_meta/comp_order) | `ContentGenerator` 协议（RuleBased/LocalLLM/Remote） |
| `AnalyticsSystem` | EventNode(kind=review) + comp_review_event + 任意邻居（通过 `GraphQueries` 取子图） | `AnalyticsModule` 协议 |

System 运行时由 `World` 容器驱动：`World.run(StudySystem())` → 内部按 Component 签名 JOIN 出符合条件的 entity 集合，逐批处理，写回对应 Component 表。

### 3.7 GraphQueries：图查询服务层（封装 CTE，不新增表）

`GraphQueries` 不是 System，也不是 Repository，而是**对 `edges` + nodes + 各 comp_* 的命名查询层**，例如：

```swift
/// 取 lemma 的 2 跳语境邻居：Lemma → appears_in → Sentence → (translates_to + aggregates_to)
func contextSubgraph(for lemmaID: EntityID, depth: Int) async throws -> Subgraph

/// 取某 Deck 下 AGAIN 率 ≥ 阈值的 Lemma（通过 produces→ReviewEvent(rating=again) 聚合）
func weakLemmas(in deckID: EntityID, thresholdAgainRatio: Double) async throws -> [EntityID]

/// co-occurrence 矩阵：在最近 N 篇 Article 中，目标 lemma_id 与其他 lemma_id 共现次数的 top-K
func synonymCooccurrence(for lemmaIDs: Set<EntityID>, window: Int) async throws -> [(EntityID, EntityID, Int)]
```

所有图遍历实现统一走 SQLite `WITH RECURSIVE`。超过 5 跳时打印警告。

### 3.8 类型集中管理（§3.4 升级版）

建 `Sources/AppTypes.swift`，集中：
- `EntityID` 类型别名、`NodeKind` 枚举
- `Rating`、`SchedulerID`、`DeckSourceKind`、`GenerationMode`、`QualityTier`
- 全部 `EdgeRel` 枚举（即 edges.rel_type 的值集合）
- `ComponentID`（每一个 comp_* 表的标识）

该文件用 `@ai` 标记为 AI 合同：不得新增 case 顺序、不得改 rawValue。

### 3.9 原 §3.1~§3.3 的废弃说明

原 §3.1（decks/cards/card_states/reviews/media_refs 单表模型）、§3.2（generated_articles/article_word_spans/custom_synonyms）、§3.3（analytics_cache/import_failures）**整体废弃**，逻辑上等价的信息全部在 3.4 的 Component 表中承载；迁移脚本在 3.5 给出。

## 4. 内容生成层（重心）

### 4.1 ContentGenerator 协议

```swift
enum QualityTier: String, Sendable { case fast, local, remote }
enum GenerationMode: String, Sendable { case generate, rewrite }

struct GenerationConstraints: Sendable {
    var maxWords: Int = 300
    var language: String = "auto"        // auto / en / zh
    var preserveTone: Bool = true        // 改写模式是否保持原文语气
    var synonymDistance: Double = 0.4    // 同义词语义距离阈值 [0,1]
}

protocol ContentGenerator: Sendable {
    static var identifier: String { get }
    static var qualityTier: QualityTier { get }

    // 模式 A：给目标词 + 主题，生成文章
    func generateArticle(targetWords: [String], topic: String,
                         constraints: GenerationConstraints) async throws -> GeneratedArticle

    // 模式 B：给现有文章 + 目标词，做同义替换
    func rewriteArticle(source: String, targetWords: [String],
                        constraints: GenerationConstraints) async throws -> GeneratedArticle
}
```

`GeneratedArticle` 包含 `body: String`、`spans: [WordSpan]`、`generatorID: String`、`tier: QualityTier`。`WordSpan` 含 `surfaceForm`、`range: Range<Int>`、`cardID: String?`、`isTarget: Bool`。

### 4.2 三档实现

| 档位 | 实现 | 用途 | 依赖 |
|---|---|---|---|
| 快速 | `RuleBasedGenerator` | 模式 B 同义词替换（默认）；模式 A 仅做模板拼句，质量有限 | 本地同义词库 |
| 本地 | `LocalLLMGenerator` | 模式 A 造文 + 高质量替换 | mlx-swift，Apple Silicon 本地推理 |
| 高质量（可选） | `RemoteAPIGenerator` | 两者都做，质量最高 | 用户自配 API Key，默认关闭 |

用户在设置里选默认档，每个生成任务可临时切换。

### 4.3 同义词库与替换规则（快速档）

- 本地数据：`~/Library/Application Support/<AppBundleID>/Thesaurus/`，初始打包 WordNet（英文）+ 可选同义词林（中文）。
- 替换流程：词形还原（lemmatize）→ 查同义词集 → 过滤（保留词性、语义距离 ≤ `synonymDistance`）→ 优先选用户目标词 → 词形还原回原屈折变化。
- 用户自定义映射表 `custom_synonyms` 覆盖默认库；deck_id 为空则全局生效。
- 替换结果在 UI 以 diff 视图呈现原词 → 替换词。

### 4.4 本地 LLM 运行时（本地档）

- 集成 `mlx-swift`（Apple MLX 框架的 Swift 绑定，Apple Silicon 原生）。
- 默认推荐模型：Qwen2.5-3B-Instruct（4-bit 量化版约 1.8GB）或 Phi-3.5-mini。
- 模型文件首次使用时让用户选：从 HuggingFace 下载（走可选联网）或手动导入 `.gguf`/`.mlpackage`。
- 推理隔离在 `LocalLLMEngine`（Sendable actor），不阻塞 UI；SwiftUI 进度通过 `AsyncStream` 推送。
- Prompt 模板内置：造文用 system prompt 指定"必须包含以下目标词，主题为 X，长度约 N 词"；改写用 system prompt 指定"保持语义，将下列词替换为目标词"。

### 4.5 可选远程 API 增强（高质量档）

- 抽象 `RemoteLLMProvider` 协议，内置 OpenAI / Anthropic / 自定义 OpenAI-compatible endpoint 三种适配器。
- 用户在设置手动填 API Key + endpoint，默认关闭。
- 每次远程调用前 UI 显式提示"将联网调用远程 API"，用户确认才发；结果可保存为本地文章，离线可复习。

## 5. 背诵与调度（基础版，由 StudySystem 驱动）

本节保持基础可用，不在此版本扩展花活。背诵交互的**唯一写入入口**是 `StudySystem`（ECS 的 System），UI 不得直接改 comp_schedule_state 或 comp_review_event。

### 5.1 Scheduler 协议（纯函数，无 I/O）

```swift
enum Rating: Int, Sendable { case again = 1, hard = 2, good = 3, easy = 4 }
enum PickStrategy: String, Sendable { case byDue, byDifficulty, byInterval, custom }

/// 纯函数调度器协议。输入当前 Card 的 SchedulingState（从 comp_schedule_state 解码而来）+ Rating + 时间，输出下一个状态。
/// 与 ECS 关系：由 StudySystem 内部持有并调用；状态 struct 直接映射 comp_schedule_state 表字段。
protocol Scheduler: Sendable {
    static var identifier: String { get }          // 写进 comp_schedule_state.scheduler_id
    var parameters: [String: Double] { get set }

    func nextState(current: SchedulingState, rating: Rating, at: Date) -> SchedulingState
    func pickNext(from: [SchedulingState], at: Date, strategy: PickStrategy) -> SchedulingState?
    mutating func fitParameters(from reviewEvents: [ReviewEvent]) throws  // 可选
}
```

默认实现：FSRS v4 调度器。SM-2 作为第二内置实现，便于对比与回退。

### 5.2 StudySystem：ECS System 负责写入

- **Component 签名（需要的组件）**：`CardNode` 存在 + `comp_text` + `comp_schedule_state`。
- **每次评分（Again/Hard/Good/Easy）做的事**：
  1. 从 comp_schedule_state 读出当前 SchedulingState。
  2. 调 scheduler.nextState(...) → 得到新 SchedulingState。
  3. 写回 comp_schedule_state。
  4. 新建一个 `EventNode(kind=review)`，挂 `comp_review_event`。
  5. 在 edges 表插一条 `produces`：src=card_id, dst=review_event_id。
- 组件签名匹配通过 EntityRegistry 的多表 JOIN 完成；写操作始终以 `nodes INSERT → 组件表 INSERT/UPDATE → edges INSERT` 的事务顺序执行。

### 5.3 背诵交互

- 卡片正反面翻转展示。
- 下方 4 级评分按钮（Again / Hard / Good / Easy）。
- 每题下方直接显示 stability / difficulty / interval 的变化量（贴合用户 UI 偏好）。
- UI 层只通过 `World.run(StudySystem(action: .rate(card: rating)))` 触发动作。

## 6. 词库导入（由 ImportSystem 翻译为 GraphNode + 若干 Component）

```swift
protocol WordImporter: Sendable {
    static var identifier: String { get }
    static var supportedExtensions: [String] { get }

    func canImport(url: URL) -> Bool

    /// 返回一组「构建计划」：Importer 自己不写库，只产出需要插入的 GraphNode 描述与 Component 数据键值对。
    /// 真正的落库由 ImportSystem 在一个数据库事务里统一执行。
    func readNodes(from url: URL,
                   progress: @escaping (Double) -> Void) async throws -> ImportBatch
}
```

`ImportBatch = (deck: DeckNodeSpec, componentsByNode: [EntitySpec: [ComponentSpec]], failures: [ImportFailureRow])`。

ImportSystem 拿到 batch 后在**单个事务**内：
1. INSERT nodes（生成稳定 EntityID：导入器可推荐自定义稳定 id 如 `cedict:<hash>`，空则用 UUID 字符串）。
2. INSERT comp_deck_meta / comp_text / comp_lemma_meta / comp_schedule_state / comp_tag_set 等组件表（ON CONFLICT 行级 upsert，便于同 deck 重复导入增量合并）。
3. INSERT edges（has / instantiates / has_state 等）。
4. 失败行（failures 列表）以 `EventNode(kind=import_failure) + comp_import_failure` 登记，并插 edge `owns: Deck → Event`。

**各格式实现要点**：
- **Anki .apkg**：.apkg 是 zip，解包得 `collection.anki2`（SQLite）+ media 归档。按 §3.5 映射表逐表翻译 ImportBatch。媒体落地到 AppSupport。
- **纯文本 CSV/TSV**：首行识别分隔符与列头，列映射对话框 + 原始 JSON 配置（贴合用户偏好）。每行生成 1 个 LemmaNode（如 CSV 有 headword/pos 列）或 1 个 CardNode（只有 front/back）的 ImportBatch。
- 失败行不中断，逐行收集到 batch.failures。

## 7. 数据分析（由 AnalyticsSystem 驱动，走 GraphQueries 子图）

```swift
struct AnalyticsScope: Sendable {
    var dateRange: ClosedRange<Date>
    var deckIDs: [EntityID]
    var schedulerID: String?
}

protocol AnalyticsModule: Sendable {
    static var identifier: String { get }
    static var displayName: String { get }
    /// 需要的 EdgeRel 集合；由 AnalyticsSystem 在调用前声明，便于预取邻居子图
    var requiredRels: [EdgeRel] { get }
    func compute(graph: GraphQueries, scope: AnalyticsScope) async throws -> any AnalyticsPayload
}
```

- `AnalyticsSystem`（System）先按 requiredRels 预取 scope 范围内的子图（GraphQueries.contextSubgraph/neighbors 系列方法），再调具体 Module，最后把结果写入 `EventNode(kind=analytics_cache) + comp_analytics_cache`。
- 内置 5 个参考模块（首批可用，后续加模块 = 加文件 + 注册）：
  1. 每日活跃度热力图（只读 comp_review_event，单表）
  2. 遗忘曲线拟合（ReviewEvent 序列 → S 曲线拟合）
  3. **薄弱词聚类**（2 跳子图：Card → produces → ReviewEvent，按 again_ratio 聚到 Lemma）
  4. 复习负载预测（comp_schedule_state.due_at 按天聚合，再乘 GraphQueries 取 deck 下子孙卡片数量）
  5. FSRS 参数拟合质量报告
- 命中缓存优先：`comp_analytics_cache.scope_hash + module_id` 命中则直接复用，计算过期再重算。

## 8. UI / 应用壳

严格贴合用户 UI 偏好。

### 8.1 窗口根层与布局

- 单 `NSVisualEffectView`，material `.headerView`，blending `.behindWindow`；标题栏、分栏、左中右三列全部透明浮在根 material 上。
- 左（持久导航）— 右（内容）主分栏；右内容区顶部是次级导航 Tab + 右上角常驻 Edit 按钮（系统标准工具栏样式）。
- 左导航：Deck 列表（树形，含目标标记穿透——父节点在含子目标时显示 "◎"）、创作入口、分析入口、设置。
- hamburger 按钮常驻，可收折左栏。
- **交互 I/O 规范**：UI 只通过 `World.run(system)`、`EntityRegistry` 的命名查询、`GraphQueries` 命名查询三类接口访问数据。不允许 UI 自己写 SQL。

### 8.2 创作视图（重心 UI）

- 右内容区切到"创作"Tab：
  - **造文** 子 Tab：左侧输入目标词列表（可从 deck 拖入或手输）+ 主题文本框；右侧生成结果，目标词在文中高亮可点击（点击跳转对应卡片或加入待复习队列）。
  - **改写** 子 Tab：左侧粘贴源文章 + 目标词列表；右侧改写结果，diff 视图显示原词 → 替换词。
- 顶部档位选择器：快速 / 本地 / 高质量（未配置则灰显）。
- 复杂配置（同义词阈值、生成长度、语言）提供"文本框编辑 JSON 配置"入口。
- 生成历史列表在创作视图侧边可回看，点击文章通过 `comp_edge_span` 反查 highlighted_in edges，高亮目标词位置。
- 落库统一走 `World.run(ContentGenSystem.generate(...))`，生成结果拆成：ArticleNode + comp_text(body) + comp_generation_meta + N × SentenceNode(若需要句子级关联) + edges.highlighted_in(Lemma→Article, 挂 comp_edge_span 位置) + edges.aggregates_to。

### 8.3 背诵视图（基础）

- 卡片翻转 + 4 级评分按钮 + 题下变化量显示。不扩展额外花活。
- 按钮点击 → `World.run(StudySystem.rate(...))`。

### 8.4 分析大屏

- 右内容区"分析"Tab：可配置 widget wall。每个 `AnalyticsModule` 自带一个 SwiftUI View，用户可拖拽排布或文本框编辑 JSON 布局。
- 计算统一 `World.run(AnalyticsSystem.compute(moduleID:scope:))`，结果从 `EntityRegistry` 读 comp_analytics_cache。

### 8.5 交互细节

- 元素变化遵守：跨行（|dy| > 25px）用 translate 平滑过渡，单行（≤25px）直接 snap；长宽直接 snap；仅 translate 不 scale；容器外裁剪 mask。
- 断点单向阈值：过断点后再移动 10px 才触发变换。

## 9. 技术栈与依赖

| 用途 | 选型 |
|---|---|
| 语言 | Swift 5.10+ |
| UI 内容 | SwiftUI 5 |
| 窗口壳 | AppKit（NSVisualEffectView、NSWindow） |
| 数据层 | GRDB.swift（nodes/edges + comp_* 组件表） |
| ECS Graph 运行时 | 自研：protocol GraphNode + Component struct + System protocol + World + EntityRegistry + GraphQueries |
| 调度算法 | 自研 FSRS v4 + SM-2 实现（被 StudySystem 调用） |
| 本地 LLM | mlx-swift |
| 同义词库 | WordNet（打包）+ 可选同义词林（导入为 maps_to edges，source_type=wordnet） |
| 远程 API | URLSession + 自研 provider 适配器 |
| 依赖管理 | Swift Package Manager |
| 最低系统 | macOS 14（SwiftUI 5 与 MLX 需要） |

## 10. 实现优先级（反映重心：ECS 骨架先，内容生成 MVP 紧随）

按依赖顺序，分三阶段；**ECS Graph Runtime 是所有模块的地基，最先做**；内容生成 MVP（快速档同义词替换 + 改写）是重心，阶段一必须跑通；背诵与分析作为配套，阶段二、三完成。

**阶段一（ECS 骨架 + 重心 MVP：改写 + 同义词替换）**
1. 项目脚手架 + AppTypes（集中所有枚举，含 NodeKind、EdgeRel、ComponentID、Rating、QualityTier 等）
2. SQLite DDL 建表迁移脚本：nodes, edges, 全部 comp_* 组件表 + 外键 CASCADE + 索引
3. `GraphNode` 协议、具体 Entity struct（Lemma/Card/Deck/Sentence/Article/Event/Edge）
4. Component struct（对应 comp_* 表，GRDB FetchableRecord/PersistableRecord）
5. `EntityRegistry`：节点/组件的读写、按组件签名 JOIN 过滤
6. `GraphQueries`：图查询命名方法集合（neighbors / contextSubgraph / weakLemmas / synonymCooccurrence），CTE 实现
7. `System` 协议 + `World` 容器
8. 4 个 System 空壳 + ImportSystem 的基础事务骨架
9. `WordImporter` 协议 + `CSVImporter`（ImportBatch 输出）
10. `ContentGenerator` 协议 + `RuleBasedGenerator`（快速档：模式 B 同义词替换，maps_to edges 为规则源）
11. `ContentGenSystem` 落库管线（ArticleNode + comp_text/comp_generation_meta + highlighted_in/appears_in edges + comp_edge_span）
12. 创作视图（改写 Tab + diff 视图 + 生成历史列表）

**阶段二（重心增强：造文 + 本地 LLM + 基础背诵）**
13. `LocalLLMGenerator`（本地档，mlx-swift）
14. 创作视图造文 Tab + 目标词高亮关联（点击高亮 span → GraphQueries 反查 Lemma→highlighted_in edges → 跳转卡片）
15. Anki `.apkg` 完整导入器（AnkiImporter，严格按 §3.5 映射表）+ `CEDICTImporter`（LemmaNode + comp_lemma_meta）+ Tatoeba（SentenceNode + appears_in edges）
16. `Scheduler` 协议 + FSRS v4 默认实现
17. `StudySystem` 完整实现（读 comp_schedule_state → 调用 Scheduler → 写回状态 + review_event + produces edge）
18. 背诵视图基础实现（翻转 + 4 评分按钮 + 变化量显示）

**阶段三（配套完善：分析 + 远程 API + UI 打磨）**
19. `AnalyticsModule` 协议 + `AnalyticsSystem` 预取子图 → 计算 → 写缓存
20. 5 个内置分析模块
21. 分析大屏 widget wall（JSON 布局模式）
22. `RemoteAPIGenerator`（高质量档，可选，需要用户手动填 API endpoint + key）
23. UI 动效打磨（translate/snap/断点 10px 单向阈值）
24. SM-2 第二调度器实现（便于对比 FSRS）
25. WordNet 同义词边批量导入：在安装或首次"造文失败"时提示"未装 WordNet 同义词词库，是否导入？"，导入后 maps_to 边数大幅提升

## 11. 范围边界

**做**：
- 纯本地优先，可选联网增强（仅限下载模型资产与可选远程 API）。
- macOS 单平台。
- Anki .apkg / CSV / TSV / CEDICT / Tatoeba / WordNet（导入为 GraphNode + Component + edges）。
- 文章生成与改写、文章-词关联、同义词替换。所有写入由 System 事务化执行。
- 模块化分析，基于子图查询，模块声明 requiredRels 预取。

**不做（本版本）**：
- 引入独立图数据库（Neo4j/ArangoDB 等）；SQLite CTE 图查询足够支撑量级。
- iOS / iPadOS 跨平台。
- iCloud 同步。
- 多用户 / 账号系统。
- 卡片排版花活（富文本编辑、模板系统）。
- 社区分享 / 词库市场。
