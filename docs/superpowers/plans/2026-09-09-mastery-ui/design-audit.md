# 现有页面 UI 审计（按页面归类）

> 本文件是 `2026-09-09-mastery-ui` 计划的**设计前置**：先把现有页面的问题按页面归类、定级、指派负责的 Task，再动代码。
>
> 审计范围：`ContentView` 三分栏里的全部页面 + 跨页共用的 `WordMarkState`。
> 方法：`WordMarkState` 的 6 个调用点 + 各页 View/ViewModel 逐一过。

---

## 总览

| 页面 | 文件 | 问题数 | P0 | P1 | P2 | 负责 Task |
|---|---|---|---|---|---|---|
| 全局壳 | `ContentView.swift` / `NavigationModel.swift` | 4 | 0 | 2 | 2 | 08 |
| 词库 | `DeckManagerView.swift` | 2 | 0 | 1 | 1 | 08 |
| 卡片浏览 | `CardBrowserView.swift` | 3 | 1 | 1 | 1 | 04 |
| 词汇 | `VocabularyInitView.swift` / `VocabularyListView.swift` | 5 | 2 | 2 | 1 | 02 / 08 |
| 阅读 | `ReadingView.swift` / `RSSViewModel.swift` | 4 | 1 | 1 | 2 | 03 / 07 |
| 创作 | `GenerateView*.swift` | 4 | 1 | 2 | 1 | 07 / 08 |
| 背诵 | `StudyView.swift` | 4 | 0 | 3 | 1 | 06 |
| 分析 | `AnalyticsView.swift` | 4 | 1 | 2 | 1 | 05 / 08 |
| 系统词典 | `SystemDictionaryView.swift` | 3 | 0 | 2 | 1 | 04 / 08 |
| 跨页共用 | `WordMarkState.swift` | 3 | 2 | 1 | 0 | 01 / 07 |

**P0 = 认知/正确性问题，必须改；P1 = 明显影响效率；P2 = 打磨项。**

---

## 1. 全局壳（`ContentView.swift` / `NavigationModel.swift`）

**现状**：三分栏自绘（一级 150/48、二级 140），页面内容由 `inset(title:navWidth:topInset:)` 包裹；创作页例外（占满全窗 + 横向滚动）；底部 `ActivityCapsuleView` 悬浮胶囊。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P1 | **布局约定分散**：`Color.clear.frame(width: navWidth)` 硬编码占位，每个页面都要自己接 `topInset`；新增页面必须记住这套暗规则 | `ContentView.swift:143-155` | 抽成 `AppContentColumn` 修饰器，页面只声明标题 |
| P1 | **没有全局查词**：找词只能进「词汇」页搜索，或进「词库」再点词典 | — | 加命令面板 / 工具栏搜索（Cmd+F 语义） |
| P2 | 创作页与其他页布局规则不一致（例外分支） | `ContentView.swift:126` | 明确「全幅页」与「列页」两类，用不同修饰器 |
| P2 | 底部胶囊浮在内容之上，长列表底部会被遮挡 | `ContentView.swift:30-33` | 给内容加底部安全间距 |

**负责**：Task 08。

---

## 2. 词库（`DeckManagerView.swift`）

**现状**：导入词库按钮 + 词库列表；卡片浏览与系统词典都是它的 `navigationDestination`。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P1 | **词典入口位置错**：词典是通用工具，却作为「词库」的子路由——用户想查词不会先去词库 | `DeckManagerView.swift:34-36, 73, 91` | 提到主导航（或全局查词），词库页只保留词库相关入口 |
| P2 | 「导入词库」是唯一主按钮，但导入不是高频操作 | `DeckManagerView.swift:44-48` | 降为工具栏次按钮 |

**负责**：Task 08。

---

## 3. 卡片浏览（`CardBrowserView.swift`）

**现状**：左卡片列表 + 右详情；每行有只读的掌握度胶囊（无记录不显示）。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P0 | **证据来源不可辨**：胶囊用 `WordMarkState` 的颜色，但用户无法分辨「这是我标的会」还是「模型认为会」 | `CardBrowserView.swift:118-130` | 胶囊用图标区分来源（手形=显式 / 波形=模型），颜色只表档位 |
| P1 | **徽章看着可点但不可点**：点击行为是「选中卡片」，徽章却长得像按钮 | 同上 | 徽章加 `allowsHitTesting(false)` 或改成明确的文字标签 |
| P2 | 卡片语义混杂：卡片是「学习目标集合」，却展示全局掌握度，容易误以为改徽章能改掌握度 | `CardBrowserView.swift:98-99` | tooltip 明确「全局掌握度，与卡片复习状态无关」 |

**负责**：Task 04。

---

## 4. 词汇（`VocabularyInitView.swift` / `VocabularyListView.swift`）

**现状**：顶部二级分段「初始化段落 / 已记录词汇」；词表行 = 状态圆点 + 词 + 状态标签 + 来源 + mastery 数值 + 概率 + seen 次数；筛选 = 全部/会/不会/出现过；排序 = 最近/频次高低。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P0 | **同一状态表达 3 次**：圆点、状态标签、mastery 数值/概率并列，互相竞争 | `VocabularyListView.swift:108-134` | 只保留「圆点 + 概率数字」；状态标签并进 tooltip |
| P0 | **筛选维度缺「学习中」**：`countByState` 统计了学习中，但筛选没有这个选项，导致学习中词在按「会/不会/出现过」筛选时全部消失 | `VocabularyListViewModel.swift:43-48` vs `66-78` | 筛选加「学习中」；或改为按概率档位筛选 |
| P1 | **两种心智模型同页**：一次性向导（初始化）与日常档案（词表）挤在一个分段里 | `VocabularyInitView.swift:9-10` | 初始化做成首次引导，词表独立成页 |
| P1 | 「阅读频次 N 次」是 `seen_count`，不是上下文多样性 | `VocabularyListView.swift:131-134` | 改为「N 个上下文 · M 次事件」（Task 02） |
| P2 | 排序「阅读多→少 / 少→多」名称含糊，且缺「掌握度」维度 | `VocabularyListViewModel.swift:19-24` | 补「掌握度高→低」（Task 02） |

**负责**：Task 02（行内表达 / 频次 / 排序）、Task 08（分段 IA / 筛选维度）。

---

## 5. 阅读（`ReadingView.swift` / `RSSViewModel.swift`）

**现状**：顶栏源 Picker + 刷新 + 5 色图例；左 270 文章列表 + 右阅读区；词块底色 + 学习中 alert 确认。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P0 | **图例颜色是第二份实现**：`Color(hue: 120/360, ...)` 手写「学习中」色，与 `WordMarkState.color` 各写一份，改一处必漏一处 | `ReadingView.swift:86-102` | 图例统一从 `WordMarkState` 取色（Task 07） |
| P1 | **用 alert 做可逆操作的确认**：学习中的词改会/不会要弹框，但这是可逆的；确认框应留给不可逆操作 | `ReadingView.swift:31-44` | 改为「长按/右键改极端 + 轻量 toast」，去掉 alert（Task 07） |
| P2 | 阅读区没有本文统计（新词数 / 不会数 / 已会数），读完不知道收获 | — | 顶栏加一行统计（Task 08） |
| P2 | 词块 hover 只给状态文案，不给概率 | `ReadingView.swift:246` | helpText 补概率（Task 03） |

**负责**：Task 03（helpText / 概率）、Task 07（图例 / 交互）。

---

## 6. 创作（`GenerateView*.swift`）

**现状**：4 列横向滚动——主题 260 / 生成方式 200 / 选词器 320（可收）/ 生成过程 260；文章词块在 `ReadText` 里，点击弹 popover。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P0 | **选词器不显示词的状态**：选词器的目标就是「挑不熟的词」，但清单只有 `plainText` + 释义，看不到掌握度/概率/词频——选词变成盲选 | `GenerateView+Columns.swift:95-108` | 清单行加概率档位色点 + 概率 + 词频带（Task 07） |
| P1 | **4 列 + 横向滚动**：窗口一窄就要横向滚，选词与看结果不能同屏 | `GenerateView+Columns.swift` | 选词器默认收起 + 可拖拽宽度；或窄窗降级为两列 |
| P1 | 生成过程与结果摘要挤在同一列 | `GenerateView+Columns.swift:129-155` | 生成完成后把结果摘要提到主区 |
| P2 | 词块 popover 只给状态，不给概率/词频 | `GenerateView.swift:124` | 补模型信息（Task 03） |

**负责**：Task 03（词块 helpText）、Task 07（选词器状态 / popover）。

---

## 7. 背诵（`StudyView.swift`）

**现状**：顶栏 5 项统计 + 闪卡 + 4 个评分按钮（1/2/3/4 快捷键）+ 剩余张数。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P0 | **快捷键 1 = 不认识且在最左**：误触代价最高，且与「最左 = 最常用」的肌肉记忆冲突 | `StudyView.swift:96-108, 137` | 改为 1–4 从左到右对应 会→不会 递增难度，或把「不认识」移出快捷键 |
| P1 | 卡片背面没有模型信息 | `StudyView.swift:78-85` | 补概率 + 词频带 + 事件摘要（Task 06） |
| P1 | 队列排除只看 mastery，模型认为已经会的词仍会反复出现 | `GraphQueries+Study.swift:46-74` | 排除条件加「模型高置信」（Task 06） |
| P2 | 没有「这张卡为什么现在出现」的解释（到期？新卡？） | — | 背面加一行来源说明（Task 06） |

**负责**：Task 06（背面 / 队列）、Task 07（快捷键）。

---

## 8. 分析（`AnalyticsView.swift`）

**现状**：「词汇能力」四卡（已会/不会/出现过/未标记，mastery 口径）+「复习表现」6 卡 + 弱词排行。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P0 | **四卡是旧口径**：全部基于 mastery 极值，与模型的概率无关 | `AnalyticsView.swift:52-75` | 改为概率档位分布（Task 05） |
| P1 | **两个层级混一页**：词汇能力（词级）与复习表现（卡片级）口径不同，放一起像一套数 | `AnalyticsView.swift:35-48` | 拆成「词汇画像」与「复习表现」两块（或两页） |
| P1 | 弱词排行只按 `againRatio`，不看概率、不看词频——高频词的低分和低频词的低分不该同权重 | `AnalyticsView.swift:151-181` | 排行加词频带列，或按「概率 × 词频」排序 |
| P2 | 无时间维度：全是当前快照 | — | 后续做趋势快照（不在本阶段） |

**负责**：Task 05、Task 08（拆分）。

---

## 9. 系统词典（`SystemDictionaryView.swift`）

**现状**：搜索框 + 条目（词头/音标/词性 + 「标为会」按钮 + 释义全文 + 数据来源）。

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P1 | **只有「标为会」一个动作**：按钮文案单向往「会」，实际是 toggle，语义误导 | `SystemDictionaryView.swift:104-111` | 文案随状态变（已会 ↔ 标为不会）（Task 04） |
| P1 | 无概率 / 词频 / 事件 | 同上 | 加「词画像」区（Task 04） |
| P2 | 入口埋在词库 | `DeckManagerView.swift:73, 91` | 提到主导航（Task 08） |

**负责**：Task 04、Task 08。

---

## 10. 跨页共用（`WordMarkState.swift`）

| 级别 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P0 | **用色相编码连续量**：`hue 0→120` 表示 mastery 1→2，导致 1.001（不会）和 1.4（学习中）视觉上都是红，边界不可辨 | `WordMarkState.color` | 颜色只表达 **3 档**（会 / 学习中 / 不会），连续概率用数字或进度条表达（Task 01） |
| P0 | **三套证据源挤在同一通道**：显式标记 / 被动 seen / 模型概率全映射到底色 | `WordMarkState.from` | 颜色只表「档位」，来源用图标/角标区分（Task 01 + 各页） |
| P1 | **图例与 helpText 各写一份**：阅读页手写图例、4 处 helpText 各自实现 | `ReadingView.swift:86-102`、4 处 `helpText(for:)` | 统一到 `WordMarkState.legendItems` + `WordMarkState.helpText`（Task 07） |

**负责**：Task 01、Task 07。

---

## 优先级汇总（P0 必改）

| # | 页面 | P0 问题 | 负责 Task |
|---|---|---|---|
| 1 | 跨页共用 | 色相编码连续量 → 改 3 档色 | 01 |
| 2 | 跨页共用 | 三套证据源同通道 → 来源用图标区分 | 01 + 04 + 07 |
| 3 | 词汇 | 同一状态表达 3 次 | 02 |
| 4 | 词汇 | 筛选缺「学习中」 | 08 |
| 5 | 阅读 | 图例颜色第二份实现 | 07 |
| 6 | 创作 | 选词器不显示状态（盲选） | 07 |
| 7 | 分析 | 四卡是 mastery 旧口径 | 05 |
| 8 | 卡片浏览 | 证据来源不可辨 | 04 |

> 背诵页「评分误触无撤销」已降级为 P1（本阶段只做视觉分隔 + 快捷键提示，撤销功能记为后续）。

---

## Task 归属调整

本审计新增两个 Task（原 task-07「回归」顺延为 task-09）：

| Task | 内容 | 来源 |
|---|---|---|
| 07 | 交互与图例统一：图例/helpText 收敛到 `WordMarkState`、去掉可逆操作的 alert（改右键菜单）、选词器显示状态 | 审计 P0 #2/#5/#6 |
| 08 | 导航与信息补齐：词典提到主导航 + 全局查词、词汇页分段 IA、分析页拆分、布局约定收敛 | 审计 P1 |
