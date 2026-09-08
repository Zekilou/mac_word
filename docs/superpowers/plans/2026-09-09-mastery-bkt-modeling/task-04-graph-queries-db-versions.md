# Task 4：`GraphQueries+Region` 补 `db:` 版本

**Files:**
- Modify: `Sources/WordRecitingApp/ECS/GraphQueries+Region.swift`
- Test: `Tests/WordRecitingAppTests/ECS/GraphQueriesRegionDbTests.swift`（新建）

**依赖：** Task 1、Task 2。

**为什么：** 项目约定「每个查询方法有两个版本」——`db:` 版本复用外层事务（System 内调用），便捷版本自开事务。`MasterySystem`（Task 5）要在写事务里读事件流与词频，必须用 `db:` 版本，否则在写事务内再开读事务会死锁。

> 注意：`GraphQueries` 是 `final class`，在 escaping 闭包里调用实例方法必须写 `self.`。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/GraphQueriesRegionDbTests.swift`：

```swift
import XCTest
import GRDB
@testable import WordRecitingApp

/// db: 版本查询必须能在写事务内使用（System 场景）。
final class GraphQueriesRegionDbTests: XCTestCase {
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

    private func record(_ lemmaIds: [EntityID], _ region: RegionRef, _ kind: WordEventKind,
                        trust: Double? = nil) throws {
        try world.run(RegionSystem(), context: .record(
            lemmaIds: lemmaIds, region: region, kind: kind, trust: trust, detail: nil))
    }

    func testDbVersionWorksInsideWriteTransaction() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .lookup)
        try record(["L1"], .dictionary(), .markUnknown, trust: 1.0)

        try appDB.dbWriter.write { db in
            let events = try world.graph.wordEvents(db, lemmaId: "L1", ascending: true)
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(Set(events.map(\.kind)), ["lookup", "mark_unknown"])
            XCTAssertEqual(try world.graph.distinctRegionCount(db, lemmaId: "L1"), 1)
            XCTAssertNil(try world.graph.lemmaFrequency(db, lemmaId: "L1"))
        }
    }

    func testAscendingAndDescendingOrders() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .lookup)

        try appDB.dbWriter.read { db in
            XCTAssertEqual(try world.graph.wordEvents(db, lemmaId: "L1", ascending: true).count, 1)
            XCTAssertEqual(try world.graph.wordEvents(db, lemmaId: "L1", ascending: false).count, 1)
        }
    }

    func testDbVersionReadsFrequency() throws {
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "test"))

        try appDB.dbWriter.write { db in
            let row = try world.graph.lemmaFrequency(db, lemmaId: "L1")
            XCTAssertEqual(row?.band, 2)
            XCTAssertEqual(row?.freqRank, 1001)
        }
    }

    func testConvenienceStillWorks() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .lookup)

        XCTAssertEqual(try world.graph.wordEvents(lemmaId: "L1").count, 1)
        XCTAssertEqual(try world.graph.distinctRegionCount(lemmaId: "L1"), 1)
        XCTAssertNil(try world.graph.lemmaFrequency(lemmaId: "L1"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GraphQueriesRegionDbTests 2>&1 | tail -5`
Expected: FAIL（`extra argument 'db' in call`）。

- [ ] **Step 3: 实现**

修改 `Sources/WordRecitingApp/ECS/GraphQueries+Region.swift`。

**3a. 用下面这段替换「某 Lemma 的全部词事件（时间倒序）」那个方法（原文件第 41–53 行）：**

```swift
    /// db 版本：复用外层事务（System 内必须用这个）。`ascending = true` 按时间升序（重放用）。
    func wordEvents(_ db: Database, lemmaId: EntityID,
                    ascending: Bool = true, limit: Int = 5000) throws -> [WordEventRow] {
        let order = ascending ? "ASC" : "DESC"
        let rows = try Row.fetchAll(db, sql: """
            SELECT entity_id, lemma_id, region_id, event_kind, trust, occurred_at
            FROM comp_word_event
            WHERE lemma_id = ?
            ORDER BY occurred_at \(order), entity_id \(order)
            LIMIT ?
            """, arguments: [lemmaId, limit])
        return rows.map(Self.makeEventRow)
    }

    /// 便捷版本：自开读事务，时间倒序。
    func wordEvents(lemmaId: EntityID, limit: Int = 500) throws -> [WordEventRow] {
        try database.dbWriter.read { db in
            try self.wordEvents(db, lemmaId: lemmaId, ascending: false, limit: limit)
        }
    }
```

**3b. 用下面这段替换「某 Lemma 出现在多少个不同 region」（原文件第 92–99 行）：**

```swift
    /// db 版本：某 Lemma 出现在多少个不同 region。
    func distinctRegionCount(_ db: Database, lemmaId: EntityID) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT region_id) FROM comp_word_event WHERE lemma_id = ?
            """, arguments: [lemmaId]) ?? 0
    }

    /// 便捷版本：自开读事务。
    func distinctRegionCount(lemmaId: EntityID) throws -> Int {
        try database.dbWriter.read { db in
            try self.distinctRegionCount(db, lemmaId: lemmaId)
        }
    }
```

**3c. 用下面这段替换「词频坐标」那个方法（原文件第 118–126 行）：**

```swift
    /// db 版本：某 Lemma 的词频坐标。
    func lemmaFrequency(_ db: Database, lemmaId: EntityID) throws -> LemmaFrequencyRow? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT band, freq_rank, source FROM comp_lemma_frequency WHERE entity_id = ?
            """, arguments: [lemmaId]) else { return nil }
        return LemmaFrequencyRow(band: row["band"], freqRank: row["freq_rank"],
                                 source: row["source"])
    }

    /// 便捷版本：自开读事务。
    func lemmaFrequency(lemmaId: EntityID) throws -> LemmaFrequencyRow? {
        try database.dbWriter.read { db in
            try self.lemmaFrequency(db, lemmaId: lemmaId)
        }
    }
```

> `wordEvents(regionId:)`、`region(regionId:)`、`allLemmaFrequencies()` 保持原样不动（本阶段不需要 db 版本）。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GraphQueriesRegionDbTests 2>&1 | tail -5`
Expected: 4 tests PASS。

- [ ] **Step 5: 回归既有查询测试**

Run: `swift test --filter GraphQueriesRegionTests 2>&1 | tail -5`
Expected: 全 PASS（便捷版本行为不变）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/ECS/GraphQueries+Region.swift \
        Tests/WordRecitingAppTests/ECS/GraphQueriesRegionDbTests.swift
git commit -m "refactor(ecs): 事件/词频/region 查询补 db 版本"
```

---
