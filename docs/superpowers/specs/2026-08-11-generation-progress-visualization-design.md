# 生成过程可视化：思考日志 + Token 指标 + 输出约定标记

- 日期：2026-08-11
- 状态：已确认设计，待实现
- 关联：docs/superpowers/specs/2026-08-11-agentic-word-embedding-design.md（逐词融入管线）、2026-08-07-word-reciting-macos-design.md

## 背景与目标

用户反馈生成过程"黑箱"：进度条只有阶段+进度，看不到模型在干嘛；且正文容易混入思考/提示词（此前出现过"输出提示词"bug）。目标：

1. **动态思考日志**（可视化思考链）：生成器每走一步发一条思考事件，**路由到左侧生成面板的进度展示区**实时渲染成日志流，不做黑箱。
2. **实时指标**：首 token 延迟、token 速率、当前动作、总耗时/token 数。
3. **输出约定标记**：所有"产出文章正文"的输出用 `===ARTICLE_START===` / `===ARTICLE_END===` 包裹，流式时在生成器内剥离标记与前置思考，保证界面与最终正文干净。
4. 生成中可**停止**。

## 已确认的关键决策

| 决策点 | 结论 |
|---|---|
| 思维链条形态 | 动态思考日志（每步实际发生时追加，含状态/详情），路由到**左侧生成面板** |
| 日志数据源 | 新增 `GenProgress.thought(GenThought)` 事件，由生成器各步骤发出（不靠 VM 猜） |
| 输出标记 | `===ARTICLE_START===` / `===ARTICLE_END===`；逐句/三句等短输出不包 |
| 流式处理 | 生成器内 `MarkedStreamBuffer` 剥离（延迟尾部技术，跨 chunk 识别），VM 只收干净 token |
| Token 指标 | VM 侧计时：阶段开始记 phaseStart，首正文 token 记 firstTokenAt；速率实时算 |
| 停止 | GlobalActivityCenter 取消 Task + 生成器关键步 `Task.checkCancellation()`（进行中的单次调用跑完，步间生效） |

## 一、思考事件模型

`LocalLLMGenerator.swift` 的 `GenProgress` 新增：

```swift
case thought(GenThought)
```

```swift
/// 生成过程中的一条思考记录（供左侧进度区渲染思考日志）。
struct GenThought: Sendable {
    enum Kind: String, Sendable { case strategy, planning, generating, embedding, polishing, saving, info }
    enum Status: String, Sendable { case running, done, failed }
    /// 稳定 id（如 "strategy"、"planning"、"embed-abandon"、"draft"、"smooth"、"skipped"），VM 按 id upsert。
    let id: String
    let kind: Kind
    let message: String      // 一行摘要
    let detail: String?      // 可展开详情（策略决策/草稿/尝试记录/失败原因）
    let status: Status
}
```

生成器各步发出的事件（示例）：
- `strategy`：running「正在制定生成策略…」→ done「策略：先写后改写（generate-rewrite）」
- `planning`：running「正在联想词义并打草稿…」→ done「规划完成（N 词聚类 M 段）」，detail=草稿
- `draft`（agentic）或正文生成：running「正在生成正文…」，done「生成正文完成（N tokens）」
- `embed-<word>`：running「融入 abandon（锚点句#0）」→ done「改写成功」/「换锚点后成功（#1）」/ failed「3 次尝试失败，跳过」，detail=尝试记录
- `smooth`：running「衔接润色…」→ done「衔接润色（N 处）」
- `skipped`：done「未融入：abandon（无法自然融入）」
- `save`（VM 设置 .saving 时发出）：running「正在保存…」→ done「保存完成」

## 二、输出约定标记 + 流式剥离

### 标记常量与提取

`AgenticPrompts` 新增：

```swift
static let articleStart = "===ARTICLE_START==="
static let articleEnd = "===ARTICLE_END==="

/// 提取两个标记之间的正文；标记缺失/半截回退 cleanArticle 全量。
static func extractMarkedBody(_ raw: String) -> String
```

### prompt 加标记指令

- `GenStrategyPrompt.plainPrompt`（agentic 纯净草稿）
- `LocalLLMGenerator.generatePrompt` / `polishPrompt` / `rewritePrompt`（plan-embed 正文/自查、RewriteView 改写）

统一追加："Start with `===ARTICLE_START===` and end with `===ARTICLE_END===`; output nothing outside these markers."

### MarkedStreamBuffer（生成器内流式剥离）

新建 `ContentGeneration/MarkedStreamBuffer.swift`，独立可测：

```swift
/// 流式剥离输出标记：跳过开标记前的思考/前言；延迟尾部技术识别跨 chunk 的结束标记。
/// @ai: 生成器在 client.stream 的 onToken 里用本缓冲清洗后再转发给 onProgress；VM 只收干净正文。
struct MarkedStreamBuffer {
    static let opening = "===ARTICLE_START==="
    static let closing = "===ARTICLE_END==="

    private(set) var rawAll = ""   // 完整原始流（最终提取用）
    private var pending = ""       // 尚未提交的字符（可能构成结束标记前缀）
    private var started = false    // 是否已越过开标记

    /// 追加一块流，返回可提交（展示）的干净文本。
    mutating func append(_ chunk: String) -> String
    /// 流结束：剥离残留结束标记与尾部杂质，返回最终干净文本。
    mutating func finalize() -> String
}
```

算法要点：
- **开标记**：在 `pending + chunk` 中找 `opening`，找到即丢弃其前全部内容（思考/前言不进入展示与最终正文）；找不到且缓冲不是 `opening` 的前缀 → 判定模型未写标记，全量展示（与 `extractMarkedBody` 回退一致）。
- **结束标记（延迟尾部）**：每次只提交"绝不可能是 `closing` 前缀"的尾部之前的部分；与 `closing` 前缀匹配的短串扣留在 `pending`，等下一块到达再判断——切碎的标记不会在界面闪出。
- **finalize**：流结束，若 `pending` 含 `closing` 则截断其前，剥离残留；`rawAll` 保留供 `extractMarkedBody` 双保险提取最终正文。

### 应用位置

| 调用 | 处理 |
|---|---|
| agentic 纯净草稿（generateViaRewrite） | `MarkedStreamBuffer` 流式 + `extractMarkedBody` |
| plan-embed 正文生成 / 自查润色 | 同上 |
| RewriteView 整篇改写 | 同上 |
| 逐词改写 / 验证 / 联想 / 锚点选句 / 衔接润色 / 跳过报告 | complete 短输出，宽容解析（既有，不包标记） |

## 三、左侧面板布局（思考日志路由目标）

生成时左侧面板在按钮区下方常驻「生成过程」区：

```
┌──────────────────────────────────────┐
│ 告诉我你想读什么、想背什么             │
│ [生成方式][主题][选词][手动输入]       │
│ [⚡ 生成文章] [⏹ 停止]               │
├──────────────────────────────────────┤
│ ⏱ 生成过程   总耗时 9.5s · 460 tokens │  ← 头
│ ──────────────────────────────────── │
│ 🧭 ✓ 策略：先写后改写（generate-rewrite） 0.4s│
│ ✏️ ✓ 规划完成（6 词聚类 3 段）▶ 详情      2.1s│
│ 📝 ⟳ 生成正文… 首token 1.2s · 12.4 tok/s  │
│ 🎯 ✓ 融入 abandon → 改写成功（锚点#0）   4.3s│
│ 🎯 ✗ 融入 abandon → 3 次失败跳过（详情）  6.8s│
│        （滚动区，最新在底部，自动滚到底）      │
│ ──────────────────────────────────── │
│ 首token 1.2s · 12.4 tok/s · 460 tokens │  ← 实时指标行
└──────────────────────────────────────┘
```

- 思考日志滚动区：每行 = 图标（按 kind）+ 状态符号（✓/⟳/✗）+ 消息 + 右侧耗时（相对生成开始）+ 详情展开按钮（DisclosureGroup）
- 实时指标行：流式阶段显示 首token / 速率 / token 数；非流式阶段显示阶段动作
- 日志区高度约 300，ScrollView + LazyVStack（遵守项目"不用 List"铁律）
- 生成完成后日志保留（可整体收起为一行「✓ 生成完成 9.5s」）

## 四、Token 指标（VM 侧计时）

`GenerateViewModel` 新增：

```swift
struct StreamStats: Equatable, Sendable {
    var firstTokenLatency: TimeInterval?  // 距流式阶段开始
    var tokens: Int = 0                   // 流式阶段已收 token 数
    var rate: Double = 0                  // tokens / 已耗时（实时）
}
```

- `.stage(.generating)` / `.stage(.polishing)`：记 `phaseStart`、重置 stats
- `.token`：首个 token 记 `firstTokenAt`（首 token 延迟 = 该值 − phaseStart）；tokens += 1；rate = tokens / (now − phaseStart)
- 总耗时/token 数：生成开始累计
- 流式阶段结束后 stats 保留在对应日志条目

## 五、停止

- 按钮：生成中「停止」→ `GlobalActivityCenter.shared.cancel(activityID)`（onCancel 已注册）
- 生成器关键步（策略/规划/逐词尝试/润色前）加 `try Task.checkCancellation()`；当前单次调用跑完后生效
- VM 捕获 `CancellationError` → `isGenerating=false`，日志追加「已取消」

## 六、文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `ContentGeneration/MarkedStreamBuffer.swift` | 新建 | 流式标记剥离（独立可测） |
| `UI/Creation/GenThinkingLogView.swift` | 新建 | 思考日志视图 + 指标行（独立视图文件，GenerateView 已 636 行） |
| `ContentGeneration/AgenticPrompts.swift` | 修改 | `articleStart/articleEnd/extractMarkedBody` |
| `ContentGeneration/GenStrategy.swift` | 修改 | `plainPrompt` 加标记指令 |
| `ContentGeneration/LocalLLMGenerator.swift` | 修改 | `GenProgress.thought` + `GenThought`；`generatePrompt/polishPrompt/rewritePrompt` 加标记；正文流式改 `MarkedStreamBuffer`；发思考事件；关键步 `checkCancellation` |
| `ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift` | 修改 | draft 流式标记 + 思考事件 + 取消检查 |
| `ContentGeneration/LocalLLMGenerator+AgenticLoop.swift` | 修改 | embedWord 发逐词思考事件（含尝试详情） |
| `UI/Creation/GenerateViewModel.swift` | 修改 | `thinkingLog` + `streamStats` + thought 路由 + 停止/取消 + save 事件 |
| `UI/Creation/GenerateView.swift` | 修改 | 左侧「生成过程」区（思考日志 + 指标 + 停止按钮） |

## 七、测试计划（全部 mock）

- `MarkedStreamBufferTests`（新建）：完整标记跨块切碎（`===ARTICLE_` + `START===\n正文`）；无开标记全量；思考前置跳过；结束标记剥离；半截结束标记（跨两块）；finalize 残留剥离；rawAll 完整保留
- `AgenticPromptsTests`（扩展）：`extractMarkedBody` 完整/缺失/半截/带思考前缀
- `AgenticEmbeddingTests`（扩展）：管线发出 thought 事件序列（strategy done → draft → embed-<word> → smooth → skipped）；embedWord 逐词 running→done/failed
- `GenerateViewModelTests`（扩展）：thought 事件 upsert 日志；流式 token 驱动 streamStats（首 token/速率）；停止 → CancellationError → isGenerating=false
- 全量回归（跳过真实模型测试类），build 0 warning

## 边界与注意

- 模型不写标记 → 前缀检测 + 全量回退，流式与最终一致，不致命。
- 文章正文恰好以 `===ART` 开头与标记前缀冲突的概率可忽略。
- 停止为步间生效（单次长调用不中断），文档注明。
- 思考日志仅内存展示，不落库（与 plan/strategy 同）。
- 真实模型推理测试一律不跑（用户约定）；只用 mock。
