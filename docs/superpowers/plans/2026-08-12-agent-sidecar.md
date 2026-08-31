# 计划：Agent Sidecar（OpenAI Agents SDK）重构文章生成管线

日期：2026-08-12
背景：生成管线鲁棒性靠手写补丁（isNoArticle 七组启发式、try? 静默失败、多轮降级），用户要求引入 agent 框架根治。已确认：**OpenAI Agents SDK（Python）** + **pyinstaller 内嵌打包 sidecar**，效果优先不限定 Swift。

## 架构定案

```
WordRecitingApp（Swift）
  └─ AgentSidecarClient（Process + Pipe，JSON Lines over stdio）
        └─ agents-sidecar（pyinstaller 单文件，内嵌于 App Bundle Resources）
              └─ OpenAI Agents SDK 0.21.1
                    ├─ Agent「文章生成」：system prompt 迁移 hardRules/reviewInstructions
                    ├─ Tools（function_tool）：
                    │    lookup_word（查释义/同义词，请求内数据，不碰 DB）
                    │    verify_embedding（目标词存在性校验）
                    │    rewrite_span（逐词改写锚点句）
                    │    clean_article（HTML/媒体/空白清洗，Python 版 TextSanitizer）
                    ├─ OutputGuardrail「文章质量」：拦截释义/规则回显/词表/哨兵/无正文
                    │    → 触发自动修正循环（SDK 内建，替代 isNoArticle 补丁）
                    └─ ModelProvider（模型 spec 隔离）：
                         配置对象 {model, base_url, api_key, is_thinking, context_window, temperature}
                         → OpenAIChatCompletionsModel（Ollama / DeepSeek / OpenAI 全兼容）
```

- **通信协议（JSONL over stdio）**：
  - Request: `{"id":1,"method":"generate","params":{mode,theme,words,definitions,synonyms,maxWords,model:{...}}}`
  - Event: `{"id":1,"type":"stage|thought|token|result|error","..."}`
- **回退**：sidecar 缺失/崩溃/超时 → 回退现有 LocalLLMGenerator 管线（可用性保障）
- **数据流**：App 查好词表/释义/同义词随请求发送，sidecar 无状态纯计算（不直连 DB）
- **模型 spec 隔离**：模型细节（思考型/温度支持/上下文窗口）集中到 ModelSpec 配置，sidecar 据此构造 client——"部分隔离模型具体 spec 增强适用模型"

## Task 清单（TDD：红灯→绿灯→commit）

1. **Sidecar 骨架 + JSONL 协议**：Python `sidecar.py`（stdin 循环 JSONL、`ping` 握手、`generate` 空实现回 error）+ Swift `AgentSidecarClient`（进程/协议解析/事件分发）；测试：协议解析、ping 握手、未知 method 错误
2. **文章生成 Agent**：OpenAI Agents SDK Agent + system prompt（迁移 hardRules）+ `clean_article` 工具 + 流式事件上报（stage/thought/token）；用 `agents.testing`/mock 模型测试 prompt 与事件
3. **OutputGuardrail 坏输出拦截**：guardrail 判定（释义开头/规则回显/词表形态/哨兵/无正文，Python 版 isNoArticle）+ tripwire 触发自动修正循环；测试覆盖各坏输出形态 + 正常文章放行
4. **工具集 + 逐词嵌入**：lookup_word / verify_embedding / rewrite_span；agent 编排（草稿→锚点→逐词改写→验证→跳过报告），迁移 AgenticEmbedding 能力
5. **模型 spec 隔离**：ModelSpec 配置对象 → sidecar 构造 OpenAIChatCompletionsModel；思考型走浅管线（计划并入初始 prompt 单次完成）；测试 provider 构造
6. **Swift 集成**：GenerateViewModel / VocabularyInitViewModel 切换 sidecar（tier 判断 + 回退）；进程生命周期（启动/崩溃重启/超时）；进度事件映射到 GenThinkingLog
7. **pyinstaller 打包内嵌**：`pyinstaller --onefile` 打包 agents-sidecar → App Bundle Resources；App 启动定位 + spawn；打包脚本 external_src/build_sidecar.sh
8. **全量回归**：现有 Swift 测试全绿 + sidecar 单元测试（Python 侧 pytest 或 Swift 集成 mock）+ build 0 warning

## 铁律遵守
- 现有 Swift 测试必须全绿（sidecar 引入不得破坏存量管线）；回退路径保证离线可用
- 文件 ≤300 行；UI 不写 SQL；build 0 warning
- sidecar Python 代码同样拆分小文件（≤300 行）
- 真实模型验证只提示用户手动跑（Ollama qwen2.5:0.5b），自动化只 mock

## 里程碑
- M1（Task 1-2）：sidecar 跑通生成（mock），Swift 端能收到事件
- M2（Task 3-5）：guardrail 拦截 + 工具嵌入 + 模型隔离（核心鲁棒性）
- M3（Task 6-8）：Swift 切换 + 打包 + 回归
