# Task 6：LemmaFrequencySystem（词频打标）

**Files:**
- Create: `Sources/WordRecitingApp/ECS/Systems/LemmaFrequencySystem.swift`
- Test: `Tests/WordRecitingAppTests/ECS/Systems/LemmaFrequencySystemTests.swift`（新建）

**依赖：** Task 3（组件）、Task 5（provider）。

**设计：** 两个操作——
- `.stamp(lemmaId:)`：单个词元增量打标（新建词元后调用）。
- `.stampAll`：全量回填（幂等，启动时调用一次；见 Task 9）。
- 表外词（`band == nil`）**不写组件**，保持「无坐标」语义，避免用 0 当默认值污染数据。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/Systems/LemmaFrequencySystemTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class LemmaFrequencySystemTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var provider: BundledWordFrequencyProvider!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        let json = """
        {"source":"test-3k","families":[
          {"rank":1,"band":1,"members":["the"]},
          {"rank":1001,"band":2,"members":["abandon","abandoned"]}
        ]}
        """
        provider = try BundledWordFrequencyProvider(data: Data(json.utf8))
    }

    private func makeLemma(_ id: String, _ text: String) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: text, textB: nil, language: nil))
    }

    private func frequency(_ lemmaId: String) throws -> LemmaFrequencyComponent? {
        try world.registry.fetchComponents(for: lemmaId, table: "comp_lemma_frequency")
    }

    func testStampSingleLemma() throws {
        try makeLemma("L1", "abandon")
        try world.run(LemmaFrequencySystem(provider: provider), context: .stamp(lemmaId: "L1"))

        XCTAssertEqual(try frequency("L1")?.band, 2)
        XCTAssertEqual(try frequency("L1")?.freqRank, 1001)
        XCTAssertEqual(try frequency("L1")?.source, "test-3k")
    }

    func testStampIsIdempotent() throws {
        try makeLemma("L1", "abandon")
        let system = LemmaFrequencySystem(provider: provider)
        try world.run(system, context: .stamp(lemmaId: "L1"))
        try world.run(system, context: .stamp(lemmaId: "L1"))

        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_lemma_frequency")
        }
        XCTAssertEqual(count, 1)
    }

    func testStampAllOnlyStampsLemmasAndSkipsOffList() throws {
        try makeLemma("L1", "the")
        try makeLemma("L2", "abandon")
        try makeLemma("L3", "zzzzz")
        try world.registry.insertNode(id: "C1", kind: .card, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "C1", textA: "the", textB: nil, language: nil))

        try world.run(LemmaFrequencySystem(provider: provider), context: .stampAll)

        XCTAssertEqual(try frequency("L1")?.band, 1)
        XCTAssertEqual(try frequency("L2")?.band, 2)
        XCTAssertNil(try frequency("L3"))
        XCTAssertNil(try frequency("C1"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter LemmaFrequencySystemTests 2>&1 | tail -5`
Expected: FAIL（`cannot find 'LemmaFrequencySystem' in scope`）。

- [ ] **Step 3: 实现**

新建 `Sources/WordRecitingApp/ECS/Systems/LemmaFrequencySystem.swift`：

```swift
import Foundation
import GRDB

/// LemmaFrequencySystem：把词频族坐标落到 Lemma 上。
/// @ai: 表外词不写组件（保持「无坐标」语义）；重复打标幂等覆盖。
struct LemmaFrequencySystem: System {
    /// 只处理带 text 组件的实体，内部再按 kind == .lemma 过滤。
    static let requiresAll: [ComponentID] = [.text]
    typealias Context = LemmaFrequencyOp

    let provider: any WordFrequencyProvider

    func execute(world: World, db: Database, entities: [EntityID], context: LemmaFrequencyOp) throws {
        switch context {
        case .stamp(let lemmaId):
            try stamp(world: world, db: db, lemmaId: lemmaId)

        case .stampAll:
            for entityId in entities {
                guard try world.registry.fetchNode(db, id: entityId)?.kind == .lemma else { continue }
                try stamp(world: world, db: db, lemmaId: entityId)
            }
        }
    }

    private func stamp(world: World, db: Database, lemmaId: EntityID) throws {
        let text: TextComponent? = try world.registry.fetchComponents(
            db, for: lemmaId, table: "comp_text")
        guard let word = text?.textA?.trimmingCharacters(in: .whitespacesAndNewlines),
              !word.isEmpty else { return }
        guard let band = provider.band(for: word) else { return }
        try world.registry.upsertComponent(db, LemmaFrequencyComponent(
            entityId: lemmaId,
            band: band,
            freqRank: provider.rank(for: word) ?? 0,
            source: provider.sourceName))
    }
}

/// LemmaFrequencySystem 的上下文操作。
enum LemmaFrequencyOp: Sendable {
    /// 单个词元增量打标。
    case stamp(lemmaId: EntityID)
    /// 全量回填（幂等）。
    case stampAll
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter LemmaFrequencySystemTests 2>&1 | tail -5`
Expected: 3 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ECS/Systems/LemmaFrequencySystem.swift \
        Tests/WordRecitingAppTests/ECS/Systems/LemmaFrequencySystemTests.swift
git commit -m "feat(ecs): LemmaFrequencySystem 词频坐标打标"
```

---
