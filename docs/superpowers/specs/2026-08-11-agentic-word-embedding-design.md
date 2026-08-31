# Agentic 逐词融入：升级 generate-rewrite 生成路径

- 日期：2026-08-11
- 状态：已确认设计，待实现
- 关联：docs/superpowers/specs/2026-08-07-word-reciting-macos-design.md（总设计）、阶段四/五生成管线

## 背景与目标

当前 `LocalLLMGenerator` 的 generate-rewrite 策略是「整篇一次改写嵌入」：正常生成草稿 → 一次 LLM 调用改写全文嵌入目标词 → 缺失词 retry → 规则兜底。问题：

- 一次调用把所有词塞进全文，上下文长、指令负载高，小模型（1.3B–7B）服从度差，容易产出释义句、生硬句或漏词。
- 无验证闭环，无法区分「融进去了」与「融得不像话」。

目标：把 generate-rewrite 升级为**逐词 agentic 循环**——每个词的融入是一个「联想 → 锚点句 → 专注改写 → 验证 → 反馈重试 → 兜底」的微观闭环，每次任务上下文极短（一句 + 一词），落在小模型能力甜区；同时用重试计数、验证评估器、降级链保证过程可预期、不卡死。

**范围**：只改 generate-rewrite 路径（`strategy.mode == .generateRewrite` 时走新管线）；plan-embed 保持不变；strategy pass 仍由 LLM 二选一。验证强度可配置（模型大小 / token 速率 / 云端 API 自适应）。

## 已确认的关键决策

| 决策点 | 结论 |
|---|---|
| 方案定位 | 升级 generate-rewrite（plan-embed 不动） |
| 代码结构 | 方案 A：extension 内聚管线（拆 prompt 文件） |
| 降级链 | 换锚点（M=1）→ 跳过；不做硬塞追加、不做文末列表 |
| 跳过词报告 | 由模型输出结构化 JSON `[{word, reason}]`，UI 覆盖 ✗ chip 悬停显示原因 |
| 验证强度 | 三档可配置（light/standard/strict），默认 standard；依据模型大小 / token 速率 / 云端 API 选择 |
| 全文 PPL 终审 | 不做（无 GPT-2 依赖，YAGNI） |

## 管线设计

```
纯净草稿（plainPrompt，现有，不约束目标词）
  → 切句（正则断句，保护缩写/引号）
  → 词语联想 + 锚点句匹配（一次 LLM 调用）
  → 逐词专注改写循环（每词 K=3）
  → 降级链：换锚点(M=1) → 跳过（结构化报告）
  → 回填 + 局部衔接润色
  → 规则兜底（仍缺失的词走 RuleBasedGenerator）
  → findTargetSpans 重算
```

### 1. 纯净草稿生成（现有）

`GenStrategyPrompt.plainPrompt(theme:maxWords:)` → `client.stream` 生成正文 → `cleanArticle` 清洗。草稿不含任何目标词约束，保证基底质量。

### 2. 切句

正则按 `. ! ?` + 后随空格/引号切分；保护常见缩写（Mr. / Dr. / e.g. / i.e. / U.S. / etc. 等）与引号内句子。输出 `[String]` 有序句子数组。不引 spaCy。

### 3. 词语联想 + 锚点句匹配（一次调用）

- **联想**：`associationPrompt` 让模型对每个目标词联想 3-5 个意象/场景/近义词。
- **锚点选句**：`anchorSelectionPrompt` 把整篇草稿 + 全部词的联想结果给模型，输出每词最契合的锚点句**索引**（JSON `{"word": index}`），已占用句自动选次高（模型决策，规则只做"去重占位"）。
- 宽容解析（同 `GenStrategyPrompt.parse` 模式）：解析失败/越界回退默认值。
- 理由：一次调用读全篇语义匹配，比逐词调用省；不引 embedding 依赖。

### 4. 逐词专注改写循环（每词 K=3）

对 `(anchorSentence, word, associations)`：

1. **专注改写** `focusedRewritePrompt`：`原句 + 目标词 + 联想 + 历史反馈` → 新句，严格保意，只输出改写后的句子。
2. **评估**（按验证等级）：
   - 存在性（规则）：词形是否出现在输出（复用 WordNormalizer 归一化匹配）。
   - 语义保真（LLM）：`verificationPrompt` 是/否判定，仅输出 `是`/`否` + 简述。
   - 重复检测（规则）：归一化文本相同或手写 Levenshtein 相似度 > 0.9 → 无效重复。
3. **反馈重试**：失败原因（缺词 / 改意 / 重复）拼进下一轮 prompt，计数器 +1，直到成功或达 K 次。

### 5. 降级链

- 达 K 次 → **换锚点**（该词相似度排名中下一个未占用句，M=1，重置计数）重新循环。
- 换锚点仍失败 → **跳过**：记录 `skipped[word] = reason`，不硬塞。
- 全部词处理完后：若存在跳过词，调 `skippedReportPrompt` 让模型输出结构化 JSON `[{word, reason}]`（与本地记录合并去重）。

### 6. 回填 + 局部衔接润色

- 将草稿中锚点句替换为改写成功句。
- 对每个替换点取前后各 1 句（越界取单侧），`coherencePrompt` 微调连接词/指代，不改核心意思；失败则原样保留（静默跳过润色）。

### 7. 规则兜底 + span

- 仍未嵌入的词（跳过词）走 `RuleBasedGenerator` 同义词替换兜底（只替换文中已有同义词，不硬塞）——现有逻辑保留。
- `findTargetSpans` 重算 spans。

## 验证强度（EmbeddingVerification）

三档，`AppSettings` 新增 `embeddingVerification`（默认 `.standard`）：

| 档位 | 存在性 | 语义保真 | 重复检测 | 适用 |
|---|---|---|---|---|
| light | ✅ 规则 | ❌ | ✅ | 本地慢速小模型 / token 速率低 |
| standard（默认） | ✅ 规则 | ✅ 每词至多一次判定 | ✅ | 通用（Ollama 本地） |
| strict | ✅ 规则 | ✅ 每次尝试 | ✅ | 云端 API / 大模型 |

设置页生成配置区新增 Picker，hint 说明三档差异。

## 进度展示

- `GenStage` 新增 `.embedding`（label「正在逐词融入…」），位于 `.generating` 之后、`.polishing` 之前。
- 新增 `GenProgress` case：`word(done: Int, total: Int, word: String)` → GenerateViewModel 暴露 `embedWordProgress`，进度条下方实时显示「3/10 battle」。
- GlobalActivityBar 托管 message 同步词级进度。

## 文件结构

| 文件 | 职责 | 约束 |
|---|---|---|
| `ContentGeneration/LocalLLMGenerator+AgenticEmbedding.swift` | 管线编排：切句 → 联想锚点 → 循环 → 回填润色 → 规则兜底 → span | ≤300 行 |
| `ContentGeneration/LocalLLMGenerator+AgenticLoop.swift` | 逐词循环 + 评估 + 降级（若编排文件超限再拆，均 extension） | ≤300 行 |
| `ContentGeneration/AgenticPrompts.swift` | 联想/选句/改写/验证/润色/跳过报告提示词 + few-shot | ≤300 行 |
| `Tests/.../ContentGeneration/AgenticEmbeddingTests.swift` | 单元测试（mock client） | — |

改动点：
- `GenStage` 加 `.embedding`；`GenProgress` 加 `word` case；`GenerateViewModel` 进度映射 + `embedWordProgress`。
- `AppSettings` + `SettingsViewModel`/`SettingsView` 加 `embeddingVerification`。
- `LocalLLMGenerator.generate` 的 generateRewrite 分支与 `generateViaRewrite` 改造为走新管线。
- `LocalLLMGenerator+RewriteStrategy.swift`：旧整篇改写逻辑移除（rewriteEmbedPrompt / retryEmbedPrompt 被 agentic 循环覆盖，删除）；`plainPrompt` 保留（纯净草稿第一步），`generateViaRewrite` 改为新管线入口。

## 测试计划

`AgenticEmbeddingTests`（全部 mock client）：
1. 切句：正常断句 / 缩写保护 / 引号内句号。
2. 锚点选句解析：合法 JSON / 宽容解析 / 越界回退。
3. 成功嵌入：词出现 + 语义通过 → 回填该句。
4. 反馈重试：首次缺词 → 反馈带原因 → 二次成功。
5. 语义否决：验证判「否」→ 触发重试。
6. 重复拦截：与历史相同输出 → 判失败。
7. 换锚点降级：K 次失败 → 换次高句重试。
8. 跳过报告：换锚点仍失败 → skipped + 结构化 JSON。
9. 回填润色：替换点前后句微调调用；润色失败静默保留。
10. 调用序列：SequenceMockClient 断言各阶段 prompt 顺序与内容。
11. 验证等级开关：light 不调语义验证；strict 每次尝试调。
12. 端到端（mock）：草稿 → 全部词嵌入 → spans 命中 → 覆盖统计。

现有测试适配：`testGenerateRewriteFlow` / `testRewriteFallbackRetryOnceWithMissingWords` 断言改为新调用序列（策略回传断言保留）。

## 边界与注意

- **本地模型上下文窗口约束（用户补充，第一优先级）**：本地模型上下文窗口普遍小（进程内 llama.cpp 默认 n_ctx=2048，小模型更小）。铁律：**每次调用的 prompt 必须短**。
  - 逐词循环（单句+单词）≈ ≤150 token；衔接润色（三句）≈ ≤120 token；跳过报告 ≈ ≤50 token——天然满足。
  - **锚点选句是全管线唯一带全文的调用**：估算草稿 token（≈ 字符数/4）；≤ 900 走一次 LLM 选句；超限降级为「联想调用（仅词，短）+ 本地词面匹配选句」（联想 token 与句子归一化词元重叠打分，未占用最高分优先），保证任何草稿长度下每次调用都短。
  - 纯净草稿生成 prompt 只含主题+长度（短）；输出由 maxTokens 约束。
  - plan-embed 的自查 pass 会把整篇塞进 prompt（既有路径风险）：长文（估算超 n_ctx 一半）跳过自查或分段自查——本轮不扩大范围，标注为已知项。
- 调用量：10 词 ≈ 20–30 次短上下文调用（1 联想锚点 + 10×(1 改写+0~1 验证) + 1 跳过报告 + 润色）。
- 小模型 JSON 不稳：所有结构化输出（选句索引、跳过报告）用宽容解析 + 规则兜底。
- window 字段保留但 agentic 下每词一句（语义=句子粒度），文档注明，不强行改变 strategy prompt。
- 不做全文 PPL 终审。
- 真实模型推理测试一律不跑（用户约定：大模型加载慢无结果）；只用 mock，真实验证由用户手动操作（小模型 Ollama 或进程内）。
