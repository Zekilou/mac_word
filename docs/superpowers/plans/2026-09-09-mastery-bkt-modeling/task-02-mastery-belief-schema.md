# Task 2：迁移 v5 + `comp_mastery_belief`

**Files:**
- Modify: `Sources/WordRecitingApp/AppTypes.swift`（`ComponentID` 末尾追加）
- Modify: `Sources/WordRecitingApp/Data/Migrations.swift`（注册 `v5_mastery_belief`）
- Create: `Sources/WordRecitingApp/ECS/MasteryComponents.swift`
- Modify: `Sources/WordRecitingApp/ECS/EntityRegistry.swift`（`tableNameMap` 追加 1 项）
- Test: `Tests/WordRecitingAppTests/Data/MasteryBeliefSchemaTests.swift`（新建）

**依赖：** 无。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/Data/MasteryBeliefSchemaTests.swift`：

```swift
import XCTest
import GRDB
@testable import WordRecitingApp

/// 阶段二：BKT 后验概率的存储层。
final class MasteryBeliefSchemaTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry { world.registry }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    func testComponentIDRawValueAppended() {
        XCTAssertEqual(ComponentID.masteryBelief.rawValue, "mastery_belief")
        XCTAssertEqual(ComponentID.allCases.last, .masteryBelief)
    }

    func testTableExists() throws {
        try appDB.dbWriter.read { db in
            XCTAssertTrue(try db.tableExists("comp_mastery_belief"))
        }
    }

    func testIndexExists() throws {
        try appDB.dbWriter.read { db in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
            XCTAssertTrue(names.contains("idx_mastery_belief_belief"))
        }
    }

    func testTableNameMapRegistersNewComponent() {
        XCTAssertEqual(EntityRegistry.tableNameMap[.masteryBelief], "comp_mastery_belief")
    }

    func testComponentRoundTrip() throws {
        let now = Date()
        try registry.insertNode(id: "L1", kind: .lemma, createdAt: now)
        try registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.73, opportunities: 4,
            lastEventAt: now, updatedAt: now, paramsVersion: "bkt-1"))

        let back: MasteryBeliefComponent? = try registry.fetchComponents(
            for: "L1", table: "comp_mastery_belief")
        XCTAssertEqual(back?.belief ?? 0, 0.73, accuracy: 0.0001)
        XCTAssertEqual(back?.opportunities, 4)
        XCTAssertEqual(back?.paramsVersion, "bkt-1")
    }

    func testCascadeOnNodeDelete() throws {
        try appDB.dbWriter.write { db in
            try registry.insertNode(db, id: "L1", kind: .lemma, createdAt: Date())
            try registry.upsertComponent(db, MasteryBeliefComponent(
                entityId: "L1", belief: 0.5, opportunities: 1,
                lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        }
        try appDB.dbWriter.write { db in try registry.deleteNode(db, id: "L1") }
        try appDB.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_mastery_belief"), 0)
        }
    }

    func testMigrationIdempotent() throws {
        XCTAssertNoThrow(try appDB.runMigrations())
        XCTAssertNoThrow(try appDB.runMigrations())
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MasteryBeliefSchemaTests 2>&1 | tail -8`
Expected: FAIL（`cannot find 'MasteryBeliefComponent' in scope`）。

- [ ] **Step 3: 实现**

**3a. `AppTypes.swift`：`ComponentID` 末尾追加**（在 `case lemmaFrequency = "lemma_frequency"` 之后）：

```swift
    /// BKT 后验掌握度概率（挂 Lemma）。
    case masteryBelief = "mastery_belief"
```

**3b. 新建 `Sources/WordRecitingApp/ECS/MasteryComponents.swift`：**

```swift
import Foundation
import GRDB

/// BKT 后验掌握度概率（挂 Lemma）。
/// @ai: 与 comp_user_known.mastery（用户显式 0/1/2 标量）并存，互不覆盖。
struct MasteryBeliefComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_mastery_belief"
    var entityId: String
    /// P(用户会这个词) ∈ (0,1)。
    var belief: Double
    /// 参与重放的事件数（学习机会数）。
    var opportunities: Int
    var lastEventAt: Date?
    var updatedAt: Date
    /// 生成该后验的参数版本（BKTParameters.version）。
    var paramsVersion: String

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case belief
        case opportunities
        case lastEventAt = "last_event_at"
        case updatedAt = "updated_at"
        case paramsVersion = "params_version"
    }
}
```

**3c. `Migrations.swift`：在 `try m.migrate(writer)` 之前追加：**

```swift
        // v5：BKT 后验掌握度概率。
        m.registerMigration("v5_mastery_belief") { db in
            try db.execute(sql: """
                CREATE TABLE comp_mastery_belief (
                    entity_id      TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                    belief         REAL NOT NULL,
                    opportunities  INTEGER NOT NULL,
                    last_event_at  DATETIME,
                    updated_at     DATETIME NOT NULL,
                    params_version TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_mastery_belief_belief ON comp_mastery_belief(belief)
                """)
        }
```

**3d. `EntityRegistry.swift`：`tableNameMap` 末尾追加：**

```swift
        .masteryBelief: "comp_mastery_belief",
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter MasteryBeliefSchemaTests 2>&1 | tail -8`
Expected: 7 tests PASS。

- [ ] **Step 5: 回归注册表与合同测试**

Run: `swift test --filter EntityRegistryTests 2>&1 | tail -5`
Run: `swift test --filter AppTypesTests 2>&1 | tail -5`
Run: `swift test --filter RegionTypesTests 2>&1 | tail -5`
Expected: 全 PASS。若 `RegionTypesTests.testNewCasesAppendedAtEnd` 断言了 `ComponentID.allCases.suffix(3)`，把它改为 `suffix(4)` 并追加 `.masteryBelief`。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/AppTypes.swift \
        Sources/WordRecitingApp/Data/Migrations.swift \
        Sources/WordRecitingApp/ECS/MasteryComponents.swift \
        Sources/WordRecitingApp/ECS/EntityRegistry.swift \
        Tests/WordRecitingAppTests/Data/MasteryBeliefSchemaTests.swift \
        Tests/WordRecitingAppTests/ECS/RegionTypesTests.swift
git commit -m "feat(ecs): 迁移 v5 与 BKT 后验组件"
```

---
