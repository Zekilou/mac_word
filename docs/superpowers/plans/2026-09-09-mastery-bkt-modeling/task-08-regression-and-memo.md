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
Expected: 阶段一基线 565 项 + 本阶段新增 ≈ 40 项，**0 failure**；`8 skipped` 中不再包含词表资源那条。

- [ ] **Step 3: 验证词频坐标真正生效**

Run:
```bash
swift test --filter WordFamilyResourceTests 2>&1 | tail -5
swift test --filter LemmaFrequencySystemTests 2>&1 | tail -5
swift test --filter MasterySystemTests 2>&1 | tail -5
```
Expected: 全 PASS，且 `WordFrequency.bundled != nil`。

- [ ] **Step 4: 备忘录增量追加**

在 `备忘录.md` **末尾追加**：

```markdown
## 阶段二「词频坐标落地 + BKT 概率化掌握度」实施计划已拆文件（2026-09-09）

计划目录：`docs/superpowers/plans/2026-09-09-mastery-bkt-modeling/`（README 总览 + task-01 ~ task-08）

- `task-01` 真实词表资源：`scripts/build_word_families.py` 支持单文件 / 按带分目录两种输入；生成并登记 `Resources/word_families.json`；修掉 `BundledWordFrequencyProviderTests` 里「用测试包 `.module` 永远 skip」的假测试
- `task-02` 迁移 v5：`comp_mastery_belief`（belief / opportunities / last_event_at / updated_at / params_version）+ `idx_mastery_belief_belief`；`ComponentID.masteryBelief`
- `task-03` `BKTModel` 纯算法：发射矩阵（6 种事件）、`band → P(L0)` 先验、CD 加成学习率、单步更新、重放
- `task-04` `GraphQueries+Region` 补 `db:` 版本（`wordEvents` / `distinctRegionCount` / `lemmaFrequency`），System 内复用外层事务
- `task-05` `MasterySystem`：重放事件流 → 后验落库；`.recompute(lemmaIds:)` / `.recomputeAll`
- `task-06` `RegionRecorder` 记完事件自动重算 + 启动 `backfillMastery`
- `task-07` 后验查询 API + 词表列表显示百分比
- `task-08` 回归 + 本归档

关键设计决定：
1. **事件流是唯一事实来源**：每次事件后**重放**该词全部事件（时间升序）得到后验，而非增量更新 → 幂等、可重算、可测试。
2. **四参数 BKT 推广为发射矩阵**：`quizCorrect/quizWrong/markKnown/markUnknown/lookup` 各有 `P(e|会)`/`P(e|不会)`；`seen` 是 0.5/0.5（无观察信息，但仍是学习机会）。
3. **trust 作为证据强度**：`P_eff = 0.5 + (P - 0.5)·trust`；trust=0 时后验不变，但学习转移照常。
4. **CD 调节学习率 P(T)**：不同 region 数越多学得越快（上限 cdCap=5），落 Contextual Diversity 的研究结论。
5. **词频带 → 先验 P(L0)**：band 1..25 线性映射 0.90..0.10；表外词用保守先验 0.30。
6. **与 `comp_user_known.mastery` 并存**：不替换用户显式 0/1/2 标量，UI 与既有测试口径不变。
7. **诚实标注**：BKT 框架与 CD 方向有文献支撑；**具体参数值与 band→P(L0) 的映射形状是启发式默认值**，全部集中在 `BKTParameters`，带 `version` 写入库；阶段三用事件日志拟合后只需改版本号并全量重算。

待办（阶段三）：BKT 参数在真实事件日志上做 EM/MLE 拟合、FSRS 全局遗忘、Nation 接受/产出 + sense 维度。
```

- [ ] **Step 5: Commit**

```bash
git add 备忘录.md
git commit -m "docs(memo): 归档阶段二计划（词表资源 + BKT）"
```

---
