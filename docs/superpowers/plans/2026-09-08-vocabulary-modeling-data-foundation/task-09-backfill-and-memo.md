# Task 9：启动回填 + 备忘录归档

**Files:**
- Create: `Sources/WordRecitingApp/ECS/VocabularyMaintenance.swift`
- Modify: `Sources/WordRecitingApp/App/main.swift`（`makeWorld()`）
- Test: `Tests/WordRecitingAppTests/ECS/VocabularyMaintenanceTests.swift`（新建）
- Modify: `备忘录.md`（**增量追加**，不覆盖）

**依赖：** Task 6、Task 8。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/VocabularyMaintenanceTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class VocabularyMaintenanceTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func provider() throws -> BundledWordFrequencyProvider {
        try BundledWordFrequencyProvider(data: Data("""
        {"source":"test","families":[
          {"rank":1,"band":1,"members":["the"]},
          {"rank":1001,"band":2,"members":["abandon"]}
        ]}
        """.utf8))
    }

    func testBackfillStampsExistingLemmas() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "the")
        VocabularyMaintenance.backfillLemmaFrequency(world: world, provider: try provider())

        XCTAssertEqual(try world.graph.lemmaFrequency(lemmaId: "L1")?.band, 2)
        XCTAssertEqual(try world.graph.lemmaFrequency(lemmaId: "L2")?.band, 1)
    }

    func testBackfillIsIdempotent() throws {
        try makeLemma("L1", "abandon")
        let p = try provider()
        VocabularyMaintenance.backfillLemmaFrequency(world: world, provider: p)
        VocabularyMaintenance.backfillLemmaFrequency(world: world, provider: p)

        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_lemma_frequency")
        }
        XCTAssertEqual(count, 1)
    }

    func testBackfillWithoutProviderIsNoOp() throws {
        try makeLemma("L1", "abandon")
        VocabularyMaintenance.backfillLemmaFrequency(world: world, provider: nil)

        XCTAssertEqual(try world.graph.allLemmaFrequencies().count, 0)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter VocabularyMaintenanceTests 2>&1 | tail -5`
Expected: FAIL（`cannot find 'VocabularyMaintenance' in scope`）。

- [ ] **Step 3: 实现**

新建 `Sources/WordRecitingApp/ECS/VocabularyMaintenance.swift`：

```swift
import Foundation

/// 词汇数据维护：启动时的一次性回填（幂等）。
/// @ai: 只在有词频 provider 时执行；失败不影响启动。
enum VocabularyMaintenance {

    /// 为全部 Lemma 回填词频坐标（已打标的会幂等覆盖）。
    static func backfillLemmaFrequency(
        world: World,
        provider: (any WordFrequencyProvider)? = WordFrequency.bundled
    ) {
        guard let provider else { return }
        try? world.run(LemmaFrequencySystem(provider: provider), context: .stampAll)
    }
}
```

- [ ] **Step 4: 接入启动流程**

修改 `Sources/WordRecitingApp/App/main.swift` 的 `makeWorld()`：

```swift
    private func makeWorld() -> World {
        do {
            let dir = try AppIdentity.ensureSupportDirectory()
            let dbPath = dir.appendingPathComponent("db.sqlite").path
            let appDB = try AppDatabase.file(dbPath)
            let world = World(database: appDB)
            // 词频坐标回填（幂等，资源缺失时自动跳过）
            VocabularyMaintenance.backfillLemmaFrequency(world: world)
            return world
        } catch {
            // 回退：进程内内存库（关 app 即丢，仅用于兜底启动）
            let appDB = (try? AppDatabase.inMemory()) ?? (try! AppDatabase.inMemory())
            let world = World(database: appDB)
            VocabularyMaintenance.backfillLemmaFrequency(world: world)
            return world
        }
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter VocabularyMaintenanceTests 2>&1 | tail -5`
Expected: 3 tests PASS。

- [ ] **Step 6: 全量回归**

Run:
```bash
swift build 2>&1 | tail -5
swift test --skip LlamaCPPProcessLocalTests --skip LlamaModelCacheTests --skip OllamaEndToEndTests 2>&1 | tail -10
```
Expected: build 0 warning / 0 error；测试全绿，且原 520 项无回归。

- [ ] **Step 7: 备忘录增量追加**

在 `备忘录.md` **末尾追加**（不覆盖已有内容）：

```markdown
### 阶段一「数据基础」实施计划已拆文件（2026-09-08）

计划目录：`docs/superpowers/plans/2026-09-08-vocabulary-modeling-data-foundation/`

- `README.md` 总览（目标 / 架构 / region 与 trust 语义 / 验收标准）
- `task-01-apptypes-contract.md` 合同扩展：`NodeKind.region`、`ComponentID.region/wordEvent/lemmaFrequency`、`RegionKind`、`WordEventKind`
- `task-02-migration-v4.md` 迁移 v4：`comp_region` / `comp_word_event` / `comp_lemma_frequency` + 3 索引
- `task-03-components-registry.md` 三个组件 + `tableNameMap` 登记
- `task-04-region-system.md` `RegionSystem`：region 幂等 + 词事件 + `produces`/`contains` 两条边
- `task-05-word-frequency-provider.md` 词频 Provider + 内置 `word_families.json` + 生成脚本
- `task-06-lemma-frequency-system.md` `LemmaFrequencySystem`（增量 / 全量回填）
- `task-07-graph-queries-region.md` 查询 API
- `task-08-wire-touch-points.md` 5 主动 + 1 被动接入点
- `task-09-backfill-and-memo.md` 启动回填 + 本归档

关键设计决定：
1. **Region 是页面/会话级上下文**，id 由业务键构造（`region-study-<cardId>` / `region-rss-<itemId>` / `region-dictionary` / `region-init-<sessionId>`），同一上下文复用同一 region。
2. **可信度两层**：region 基础 trust（主动 1.0 / 被动 0.0）+ 事件级覆盖（`override ?? region.trust`）。被动 region 里的主动标记可提升到 1.0。
3. **事件流落 `comp_word_event`**（冗余 `lemma_id` / `region_id` + 两索引），避免每次都 join `edges`；同时保留两条边保证图语义。
4. **表外词不写词频组件**，保持「无坐标」语义，不用 0 当默认值。
5. 词频带只作**参考坐标**，不作硬阈值判定（Kremmel & Schmitt 2023 对 98% 阈值的复制质疑）。

待办（阶段二起）：BKT 概率化 mastery、FSRS 接入全局遗忘、CD 用 `distinctRegionCount` 做上下文多样性、Nation 接受/产出 + sense 维度。
```

- [ ] **Step 8: Commit**

```bash
git add Sources/WordRecitingApp/ECS/VocabularyMaintenance.swift \
        Sources/WordRecitingApp/App/main.swift \
        Tests/WordRecitingAppTests/ECS/VocabularyMaintenanceTests.swift \
        备忘录.md
git commit -m "feat(app): 启动回填词频坐标并归档阶段一计划"
```

---
