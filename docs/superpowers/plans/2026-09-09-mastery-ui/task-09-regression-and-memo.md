# Task 9：全量回归 + 冒烟 + 备忘录归档

**Files:**
- Modify: `备忘录.md`（**增量追加**，不覆盖）

**依赖：** Task 1–8。

---

- [ ] **Step 1: 构建**

Run: `swift build 2>&1 | tail -10`
Expected: 0 warning、0 error。

- [ ] **Step 2: 全量测试**

Run:
```bash
swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests 2>&1 | tail -10
```
Expected: 0 failure。

- [ ] **Step 3: 口径一致性检查**

用 Grep 工具搜 `WordMarkState.from(mastery:` 于 `Sources/WordRecitingApp`。

Expected: **只剩 `WordMarkState.swift` 内部一处**（`from(belief:mastery:seenCount:)` 的回退调用）。其余调用点必须传 `belief:`。

- [ ] **Step 4: 前端专项回归**

Run:
```bash
swift test --filter WordMarkStateTests 2>&1 | tail -5
swift test --filter MasteryPresentationTests 2>&1 | tail -5
swift test --filter VocabularyListViewModelTests 2>&1 | tail -5
swift test --filter VocabularyInitViewModelTests 2>&1 | tail -5
swift test --filter RSSViewModelTests 2>&1 | tail -5
swift test --filter GenerateArticleWordsTests 2>&1 | tail -5
swift test --filter GenerateViewModelTests 2>&1 | tail -5
swift test --filter EventTimelinePresenterTests 2>&1 | tail -5
swift test --filter SystemDictionaryTests 2>&1 | tail -5
swift test --filter AnalyticsViewModelTests 2>&1 | tail -5
swift test --filter StudyViewModelTests 2>&1 | tail -5
```
Expected: 全 PASS。

- [ ] **Step 5: 手动冒烟清单（对照 `design-audit.md`）**

Run: `swift run 2>&1 | tail -5`

| 页面 | 检查点 | 预期 | 对应审计项 |
|---|---|---|---|
| 词汇页 | 「用户标会但模型概率低」的词 | 显示为**不会**（概率优先），旁边有百分比 | P0 #1 |
| 词汇页 | 任一有事件的词 | 「N 个上下文 · M 次事件」，不再是「阅读频次」 | P1 |
| 词汇页 | 筛选选「学习中」 | 能筛出概率在 0.20~0.85 的词 | P0 #4 |
| 词汇页 | 一行内的状态表达 | 只剩「圆点 + 概率数字」，不再三重表达 | P0 #3 |
| 阅读页 | 图例 | 与 `WordMarkState.legendItems` 一致，无手写颜色 | P0 #5 |
| 阅读页 | 点击词块 | 左键直接标不会（无弹窗）；右键出「标为会 / 标为不会」 | P0 #2 |
| 初始化 / 生成文章 | 同上 | 同上 | P0 #2 |
| 创作页 | 选词器清单 | 每行有概率徽章（百分比 + 档位色） | P0 #6 |
| 卡片浏览 | 词条胶囊 | 概率档位 + 来源图标（手形=显式 / 波形=模型） | P0 #8 |
| 词典 | 主导航「词典」 | 可直接进入，无需先开词库；按钮文案随状态 | P1 |
| 词典 | 查一个学过的词 | 词画像：概率 + 词频带 + 事件时间线 | — |
| 分析页 | 「掌握度分布」 | 四卡为概率档位 | P0 #7 |
| 分析页 | 「词汇量画像」 | 估算 + 分带条形图 + 95%/98% 参照 + 免责说明 | — |
| 分析页 | 「复习表现」 | 明确标注「卡片维度，与词汇画像不是同一层级」 | P1 |
| 背诵页 | 卡片背面 | 概率 + 词频带 + 事件摘要 | P1 |
| 背诵页 | 评分按钮 | 「不认识」与其余三键有视觉分隔；每键下方显示快捷键 | P1 |
| 背诵页 | 模型概率 ≥0.9 的卡 | 不再进队列 | P0 |
| 全局 | 清空数据库后启动 | 各页空态正常，不崩 | — |

- [ ] **Step 6: 备忘录增量追加**

在 `备忘录.md` **末尾追加**：

```markdown
## 前端改造计划（概率主口径 + 逐页审计）已完成（2026-09-09）

计划目录：`docs/superpowers/plans/2026-09-09-mastery-ui/`
- `README.md` 总览 + P0 结论
- `design-audit.md` **按现有页面归类的 UI 审计**（全局壳/词库/卡片浏览/词汇/阅读/创作/背诵/分析/词典/跨页共用），每条带 P0/P1/P2 + 文件行号 + 负责 Task
- `task-01`~`task-09`

落地内容：
- `WordMarkState` 改概率主口径（`from(belief:mastery:seenCount:)`、`.learning` 载荷 0~1、3 档单一色不再渐变、`legendItems`、`knownThreshold=0.85`/`unknownThreshold=0.20`）
- 六个页面判定全部改由概率驱动；无概率时回退用户显式标记
- 交互改造：左键=标不会、右键=改极端（去掉 3 处可逆 alert）、图例收敛、选词器显示概率徽章
- 分析页：四卡 → 概率档位分布 + 词频带画像 + 词汇量估算
- 复习页：队列排除改「显式标记会 或 模型高置信（≥0.90）」、卡片背面模型信息
- 导航：词典入主导航；词表筛选补「学习中」

审计中降级/后续的项：背诵页「评分误触无撤销」本阶段只做视觉分隔 + 快捷键提示，撤销功能需 System 层回滚支持，记为后续。
```

- [ ] **Step 7: Commit**

```bash
git add 备忘录.md
git commit -m "docs(memo): 归档前端改造（概率主口径 + 逐页审计）"
```

---
