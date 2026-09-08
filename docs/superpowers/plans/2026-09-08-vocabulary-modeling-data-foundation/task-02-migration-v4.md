# Task 2：迁移 v4（region / 词事件 / 词频表）

**Files:**
- Modify: `Sources/WordRecitingApp/Data/Migrations.swift`（在 `try m.migrate(writer)` **之前**注册 v4）
- Test: `Tests/WordRecitingAppTests/Data/RegionSchemaTests.swift`（新建）

**依赖：** Task 1（`NodeKind.region`）。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/Data/RegionSchemaTests.swift`：

```swift
import XCTest
import GRDB
@testable import WordRecitingApp

/// 阶段一：v4 迁移建表 / 索引 / 级联。
final class RegionSchemaTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry { world.registry }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    func testV4TablesExist() throws {
        try appDB.dbWriter.read { db in
            for table in ["comp_region", "comp_word_event", "comp_lemma_frequency"] {
                XCTAssertTrue(try db.tableExists(table), "缺表：\(table)")
            }
        }
    }

    func testV4IndexesExist() throws {
        try appDB.dbWriter.read { db in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
            XCTAssertTrue(names.contains("idx_word_event_lemma_time"))
            XCTAssertTrue(names.contains("idx_word_event_region"))
            XCTAssertTrue(names.contains("idx_region_source"))
        }
    }

    func testV4Idempotent() throws {
        XCTAssertNoThrow(try appDB.runMigrations())
        XCTAssertNoThrow(try appDB.runMigrations())
    }

    func testWordEventCascadeOnNodeDelete() throws {
        let now = Date()
        try appDB.dbWriter.write { db in
            try registry.insertNode(db, id: "L1", kind: .lemma, createdAt: now)
            try registry.insertNode(db, id: "R1", kind: .region, createdAt: now)
            try registry.insertNode(db, id: "E1", kind: .event, createdAt: now)
            try registry.upsertComponent(db, WordEventComponent(
                entityId: "E1", lemmaId: "L1", regionId: "R1",
                eventKind: WordEventKind.seen.rawValue, trust: 0,
                occurredAt: now, detailJson: nil))
        }
        try appDB.dbWriter.write { db in try registry.deleteNode(db, id: "E1") }
        try appDB.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_word_event"), 0)
        }
    }
}
```

> 该测试引用了 `WordEventComponent`，由 Task 3 提供。若单独跑本 Task，先完成 Task 3 的 Step 3a。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RegionSchemaTests 2>&1 | tail -5`
Expected: FAIL（`no such table: comp_region` / 编译错误）。

- [ ] **Step 3: 实现迁移**

修改 `Sources/WordRecitingApp/Data/Migrations.swift`，在 `try m.migrate(writer)`（约第 50 行）**之前**插入：

```swift
        // v4：词汇显示上下文（region）+ 全量词事件流 + 词频族坐标。
        m.registerMigration("v4_region_and_word_event") { db in
            try db.execute(sql: """
                CREATE TABLE comp_region (
                    entity_id  TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    kind       TEXT NOT NULL,
                    label      TEXT,
                    source_id  TEXT,
                    trust      REAL NOT NULL,
                    created_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE comp_word_event (
                    entity_id   TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    lemma_id    TEXT NOT NULL,
                    region_id   TEXT NOT NULL,
                    event_kind  TEXT NOT NULL,
                    trust       REAL NOT NULL,
                    occurred_at DATETIME NOT NULL,
                    detail_json TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE comp_lemma_frequency (
                    entity_id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    band      INTEGER NOT NULL,
                    freq_rank INTEGER NOT NULL,
                    source    TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_word_event_lemma_time ON comp_word_event(lemma_id, occurred_at)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_word_event_region ON comp_word_event(region_id)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_region_source ON comp_region(source_id)
                """)
        }
```

设计说明：
- `comp_word_event` 里冗余存 `lemma_id` / `region_id`，是为了让「某词全部事件」「某 region 全部事件」都是**索引扫描**，避免每次查询都去 join `edges`。两条边仍然写（Task 4），保证图语义完整。
- 列名用 `freq_rank` 而非 `rank`：`rank` 是 SQLite 窗口函数关键字，避免解析歧义。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RegionSchemaTests 2>&1 | tail -5`
Expected: 4 tests PASS。

- [ ] **Step 5: 回归迁移测试**

Run: `swift test --filter MigrationsTests 2>&1 | tail -5`
Expected: 全 PASS。若 `testAllTablesExist` / `testCompTablesHaveEntityIdPK` 用**精确集合断言**，把三张新表名追加到期望列表末尾；若 `testIndexesExist` 同理，追加三个索引名。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/Data/Migrations.swift Tests/WordRecitingAppTests/Data/RegionSchemaTests.swift
git commit -m "feat(ecs): 迁移 v4 建 region/词事件/词频表与索引"
```

---
