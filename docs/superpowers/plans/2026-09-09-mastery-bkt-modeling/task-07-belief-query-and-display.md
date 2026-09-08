# Task 7：查询 API + 词表列表展示掌握度

**Files:**
- Create: `Sources/WordRecitingApp/ECS/GraphQueries+Mastery.swift`
- Modify: `Sources/WordRecitingApp/ECS/GraphQueries+Vocabulary.swift`（`RecordedLemma` 加 `belief` + SQL LEFT JOIN）
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyListViewModel.swift`（`beliefText`）
- Modify: `Sources/WordRecitingApp/UI/Init/VocabularyListView.swift`（行内展示）
- Test: `Tests/WordRecitingAppTests/ECS/GraphQueriesMasteryTests.swift`（新建）
- Test: `Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift`（追加）

**依赖：** Task 5。

---

- [ ] **Step 1: 写失败测试**

**1a. 新建 `Tests/WordRecitingAppTests/ECS/GraphQueriesMasteryTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

final class GraphQueriesMasteryTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries { world.graph }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    func testMasteryBeliefQueries() throws {
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.62, opportunities: 3,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        XCTAssertEqual(try graph.masteryBelief(lemmaId: "L1") ?? 0, 0.62, accuracy: 0.0001)
        XCTAssertNil(try graph.masteryBelief(lemmaId: "missing"))
        XCTAssertEqual(try graph.allMasteryBeliefs().count, 1)
    }

    func testRecordedLemmaCarriesBelief() throws {
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 1,
            source: "init", updatedAt: Date()))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.81, opportunities: 5,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        let entry = try XCTUnwrap(try graph.recordedLemmas().first)
        XCTAssertEqual(entry.belief ?? 0, 0.81, accuracy: 0.0001)
    }

    func testRecordedLemmaBeliefIsNilWithoutBeliefRow() throws {
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 1,
            source: "init", updatedAt: Date()))

        let entry = try XCTUnwrap(try graph.recordedLemmas().first)
        XCTAssertNil(entry.belief)
    }
}
```

**1b. 在 `Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift` 末尾追加：**

```swift
    func testBeliefTextFormatting() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 1,
            source: "init", updatedAt: Date()))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.847, opportunities: 5,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)
        XCTAssertEqual(vm.beliefText(entry), "85%")
    }

    func testBeliefTextIsNilWithoutBelief() throws {
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 1,
            source: "init", updatedAt: Date()))

        let vm = VocabularyListViewModel(world: world)
        let entry = try XCTUnwrap(vm.entries.first)
        XCTAssertNil(vm.beliefText(entry))
    }
```

> 该测试文件的 `setUp` 里已有 `world`（`AppDatabase.inMemory()` + `World(database:)`）；若变量名不同，用文件内已有的写法。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GraphQueriesMasteryTests 2>&1 | tail -5`
Expected: FAIL（`value of type 'GraphQueries' has no member 'masteryBelief'`）。

- [ ] **Step 3: 实现**

**3a. 新建 `Sources/WordRecitingApp/ECS/GraphQueries+Mastery.swift`：**

```swift
import Foundation
import GRDB

/// GraphQueries 扩展：BKT 后验掌握度查询。
/// @ai: 业务代码禁止手写 SQL，必须走本扩展的命名方法。
extension GraphQueries {

    /// db 版本：某 Lemma 的模型估计掌握度概率；nil = 尚无事件。
    func masteryBelief(_ db: Database, lemmaId: EntityID) throws -> Double? {
        try Double.fetchOne(db, sql: """
            SELECT belief FROM comp_mastery_belief WHERE entity_id = ?
            """, arguments: [lemmaId])
    }

    /// 便捷版本：自开读事务。
    func masteryBelief(lemmaId: EntityID) throws -> Double? {
        try database.dbWriter.read { db in
            try self.masteryBelief(db, lemmaId: lemmaId)
        }
    }

    /// 全部后验概率（批量，供列表展示）。
    func allMasteryBeliefs() throws -> [EntityID: Double] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, belief FROM comp_mastery_belief
                """)
            var result: [EntityID: Double] = [:]
            for row in rows { result[row["entity_id"]] = row["belief"] }
            return result
        }
    }
}
```

**3b. `GraphQueries+Vocabulary.swift`：`RecordedLemma` 末尾追加字段（带默认值，保持既有构造点兼容）：**

```swift
        /// BKT 后验掌握度概率；nil = 尚无事件。
        let belief: Double? = nil
```

**3c. 同文件 `recordedLemmas()` 的 SQL 与映射改为：**

```swift
    func recordedLemmas() throws -> [RecordedLemma] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT k.entity_id, t.text_a AS text, t.text_b AS definition,
                       k.mastery, k.seen_count, k.source, k.updated_at,
                       b.belief AS belief
                FROM comp_user_known k
                LEFT JOIN comp_text t ON t.entity_id = k.entity_id
                LEFT JOIN comp_mastery_belief b ON b.entity_id = k.entity_id
                WHERE k.mastery > 0 OR k.seen_count > 0
                ORDER BY k.updated_at DESC, k.entity_id DESC
                """)
            return rows.map { row in
                RecordedLemma(lemmaID: row["entity_id"],
                              text: TextSanitizer.clean(row["text"], preserveLineBreaks: false) ?? "",
                              definition: TextSanitizer.clean(row["definition"], preserveLineBreaks: true),
                              mastery: row["mastery"], seenCount: row["seen_count"],
                              source: row["source"], updatedAt: row["updated_at"],
                              belief: row["belief"])
            }
        }
    }
```

**3d. `VocabularyListViewModel.swift`：追加：**

```swift
    /// 掌握度概率展示文案（nil = 尚无模型数据）。
    func beliefText(_ e: GraphQueries.RecordedLemma) -> String? {
        guard let belief = e.belief else { return nil }
        return "\(Int((belief * 100).rounded()))%"
    }
```

**3e. `VocabularyListView.swift` 的 `row(_:)`：在既有 `if e.mastery > 0 { ... }` 块之后插入：**

```swift
                    if let beliefText = vm.beliefText(e) {
                        Text(beliefText)
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .help("模型估计掌握度（BKT 后验概率，随事件更新）")
                    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GraphQueriesMasteryTests 2>&1 | tail -5`
Run: `swift test --filter VocabularyListViewModelTests 2>&1 | tail -5`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ECS/GraphQueries+Mastery.swift \
        Sources/WordRecitingApp/ECS/GraphQueries+Vocabulary.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyListViewModel.swift \
        Sources/WordRecitingApp/UI/Init/VocabularyListView.swift \
        Tests/WordRecitingAppTests/ECS/GraphQueriesMasteryTests.swift \
        Tests/WordRecitingAppTests/UI/VocabularyListViewModelTests.swift
git commit -m "feat(mastery): 后验查询 API 与词表掌握度展示"
```

---
