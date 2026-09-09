# Task 8：全量回归 + 备忘录归档

**Files:**
- Modify: `备忘录.md`（**增量追加**，不覆盖）

**依赖：** Task 1–7。

---

- [ ] **Step 1: 构建**

Run: `swift build 2>&1 | tail -10`
Expected: 0 warning、0 error。

- [ ] **Step 2: 全量测试**

Run:
```bash
swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests 2>&1 | tail -10
```
Expected: 0 failure；总数 = 基线 745 + 本阶段新增（约 45）。

- [ ] **Step 3: 默认行为不变校验**

Run:
```bash
swift test --filter SM2IntervalPolicyTests 2>&1 | tail -5
swift test --filter StudyPolicyTests 2>&1 | tail -5
swift test --filter GenerateViewModelTests 2>&1 | tail -5
swift test --filter AppSettingsTests 2>&1 | tail -5
```
Expected: 全 PASS。重点确认：
- 默认 `schedulerID == .sm2` 时 `StudySystem` 产出的 `intervalDays` 与升级前一致（3 / 10 / 9.4 / 13 等）。
- 默认 `wordScoringID == .random` 时 `randomPick` 仍返回 `randomCount` 个词。

- [ ] **Step 4: 手动冒烟**

Run: `swift run 2>&1 | tail -5`

| 场景 | 预期 |
|---|---|
| 设置 → 通用 → 复习调度 | 出现「SM-2 + 词频调制」选项；选中后背诵评分，高频词下次间隔明显变长 |
| 设置 → 通用 → 选词策略 | 出现「随机 / 临界词优先 / 词频优先」 |
| 创作 → 选词器 | 策略下拉生效；说明文案随策略变化；「按策略选词」按钮 |
| 选「临界词优先」后点选词 | 选中的词概率大致落在 0.2~0.85 区间 |
| 选「词频优先」后点选词 | 优先选中词频带小的词（表外词排最后） |
| 切回「随机」 | 行为与升级前一致 |

- [ ] **Step 5: 备忘录增量追加**

在 `备忘录.md` **末尾追加**：

```markdown
## 可插拔调度层（2026-09-09）

设计：`docs/superpowers/specs/2026-09-09-scheduling-strategies-design.md`
计划：`docs/superpowers/plans/2026-09-09-scheduling-strategies/`（README + task-01~08）

**动机**：概率/词频/事件流已入库，但决策层仍是单轨硬编码（复习固定 SM-2、造文纯随机、初始化 prompt 写死「高频词」）。

**架构（三层，策略不碰 DB）**
- 特征层 `WordFeatures` + `GraphQueries+Features`：一次 SQL 拿全 belief / band / rank / 事件聚合 / 卡片调度。
- 决策层 `WordScoringStrategy`（选词打分）+ `ReviewIntervalPolicy`（排期算间隔），纯函数。
- 注册层 `SchedulingRegistry` + 设置项。

**新增策略**
- 选词：`random`（复刻旧行为）/ `criticalWords`（概率 0.5 附近最优先）/ `frequencyTier`（词频带优先，支持 bandWindow）。
- 排期：`sm2`（逐字复刻原公式）/ `sm2Frequency`（高频 ×1.3、低频 ×0.8、高置信 ×1.5，均为**启发式默认值**）。

**关键决定**
1. 复用 `SchedulerID` 作排期策略 id（它本来就是 `comp_schedule_state.scheduler_id`），只追加 `.sm2Frequency`；选词新建 `WordScoringID`。
2. 默认值保持旧行为：`schedulerID == .sm2` + `wordScoringID == .random` 时手感不变。
3. 不改 schema：`stability`/`difficulty` 本来就是 FSRS 形状，接 FSRS 只需新增策略。
4. 词频表缺失（`band == nil`）时策略走保守分支（排最后 / 不加成）。

**后续**：S4 内容侧（初始化段落 bandWindow + 阅读高亮阈值）、S5 FSRS 排期策略。
```

- [ ] **Step 6: Commit**

```bash
git add 备忘录.md
git commit -m "docs(memo): 归档可插拔调度层"
```

---
