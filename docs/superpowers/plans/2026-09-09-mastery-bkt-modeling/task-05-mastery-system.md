# Task 5：`MasterySystem`（重放事件流算后验）

**Files:**
- Create: `Sources/WordRecitingApp/ECS/Systems/MasterySystem.swift`
- Test: `Tests/WordRecitingAppTests/ECS/Systems/MasterySystemTests.swift`（新建）

**依赖：** Task 2（组件）、Task 3（算法）、Task 4（db 版本查询）。

**设计：** 一个 Lemma 的全部事件按时间升序重放 → 后验写 `comp_mastery_belief`。无事件则不写组件。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/Systems/MasterySystemTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class MasterySystemTests: XCTestCase {
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

    private func belief(_ lemmaId: String) throws -> MasteryBeliefComponent? {
        try world.registry.fetchComponents(for: lemmaId, table: "comp_mastery_belief")
    }

    func testNoEventsWritesNoComponent() throws {
        try makeLemma("L1", "abandon")
        try world.run(MasterySystem(), context: .recompute(lemmaIds: ["L1"]))
        XCTAssertNil(try belief("L1"))
    }

    func testRecomputeFromEventStream() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .markUnknown, trust: 1.0)
        try record(["L1"], .dictionary(), .markUnknown, trust: 1.0)

        try world.run(MasterySystem(), context: .recompute(lemmaIds: ["L1"]))

        let result = try XCTUnwrap(try belief("L1"))
        XCTAssertLessThan(result.belief, 0.30)
        XCTAssertEqual(result.opportunities, 2)
        XCTAssertEqual(result.paramsVersion, BKTParameters.default.version)
        XCTAssertNotNil(result.lastEventAt)
    }

    func testMarkKnownRaisesAbovePrior() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .markKnown, trust: 1.0)

        try world.run(MasterySystem(), context: .recompute(lemmaIds: ["L1"]))

        let result = try XCTUnwrap(try belief("L1"))
        XCTAssertGreaterThan(result.belief, BKTParameters.default.fallbackPrior)
    }

    func testRecomputeIsIdempotent() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .dictionary(), .markUnknown, trust: 1.0)
        try record(["L1"], .dictionary(), .markKnown, trust: 1.0)

        try world.run(MasterySystem(), context: .recompute(lemmaIds: ["L1"]))
        let first = try XCTUnwrap(try belief("L1")).belief
        try world.run(MasterySystem(), context: .recompute(lemmaIds: ["L1"]))
        let second = try XCTUnwrap(try belief("L1")).belief

        XCTAssertEqual(first, second, accuracy: 0.0001)
        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_mastery_belief")
        }
        XCTAssertEqual(count, 1)
    }

    func testFrequencyBandShiftsPrior() throws {
        try makeLemma("L1", "the")
        try makeLemma("L2", "abandon")
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 1, freqRank: 1, source: "test"))
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L2", band: 25, freqRank: 25000, source: "test"))
        try record(["L1", "L2"], .rss(articleId: "A1", title: nil), .seen, trust: 0)

        try world.run(MasterySystem(), context: .recompute(lemmaIds: ["L1", "L2"]))

        let high = try XCTUnwrap(try belief("L1")).belief
        let low = try XCTUnwrap(try belief("L2")).belief
        XCTAssertGreaterThan(high, low)
    }

    func testContextDiversityIncreasesBelief() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "ability")
        for _ in 0..<5 {
            try record(["L1"], .rss(articleId: "A1", title: nil), .seen, trust: 0)
        }
        for index in 0..<5 {
            try record(["L2"], .rss(articleId: "A\(index)", title: nil), .seen, trust: 0)
        }

        try world.run(MasterySystem(), context: .recompute(lemmaIds: ["L1", "L2"]))

        let same = try XCTUnwrap(try belief("L1")).belief
        let diverse = try XCTUnwrap(try belief("L2")).belief
        XCTAssertGreaterThan(diverse, same)
    }

    func testRecomputeAllOnlyProcessesLemmas() throws {
        try makeLemma("L1", "abandon")
        try world.registry.insertNode(id: "C1", kind: .card, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "C1", textA: "abandon", textB: nil, language: nil))
        try record(["L1"], .dictionary(), .markKnown, trust: 1.0)

        try world.run(MasterySystem(), context: .recomputeAll)

        XCTAssertNotNil(try belief("L1"))
        XCTAssertNil(try belief("C1"))
        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_mastery_belief")
        }
        XCTAssertEqual(count, 1)
    }

    func testUnknownEventKindIsSkipped() throws {
        try makeLemma("L1", "abandon")
        try world.registry.insertNode(id: "E1", kind: .event, createdAt: Date())
        try world.registry.upsertComponent(WordEventComponent(
            entityId: "E1", lemmaId: "L1", regionId: "region-dictionary",
            eventKind: "legacy_unknown_kind", trust: 1.0,
            occurredAt: Date(), detailJson: nil))

        try world.run(MasterySystem(), context: .recompute(lemmaIds: ["L1"]))

        let result = try XCTUnwrap(try belief("L1"))
        XCTAssertEqual(result.opportunities, 1)
        XCTAssertEqual(result.belief, BKTParameters.default.fallbackPrior, accuracy: 0.0001)
    }
}
```

> 最后一条测试：未知 `event_kind` 无法映射到 `WordEventKind`，被跳过（后验 = 先验），但事件数仍计入 `opportunities`。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MasterySystemTests 2>&1 | tail -5`
Expected: FAIL（`cannot find 'MasterySystem' in scope`）。

- [ ] **Step 3: 实现**

新建 `Sources/WordRecitingApp/ECS/Systems/MasterySystem.swift`：

```swift
import Foundation
import GRDB

/// MasterySystem：把词事件流重放成 BKT 后验概率，写入 comp_mastery_belief。
/// @ai: 事件流是唯一事实来源；重放幂等（同一事件序列 → 同一后验）。
///      requiresAll 为空 = 纯 op 驱动，不依赖 entity 集合（见 World.run）。
struct MasterySystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = MasteryOp

    let parameters: BKTParameters

    init(parameters: BKTParameters = .default) {
        self.parameters = parameters
    }

    func execute(world: World, db: Database, entities: [EntityID], context: MasteryOp) throws {
        switch context {
        case .recompute(let lemmaIds):
            for lemmaId in lemmaIds {
                try recompute(world: world, db: db, lemmaId: lemmaId)
            }

        case .recomputeAll:
            let candidates = try world.registry.filterEntityIDs(db, requiringAll: [.text])
            for entityId in candidates {
                guard try world.registry.fetchNode(db, id: entityId)?.kind == .lemma else { continue }
                try recompute(world: world, db: db, lemmaId: entityId)
            }
        }
    }

    /// 重放单个 Lemma 的全部事件（时间升序）→ 写后验。无事件则不写。
    private func recompute(world: World, db: Database, lemmaId: EntityID) throws {
        let events = try world.graph.wordEvents(db, lemmaId: lemmaId, ascending: true)
        guard !events.isEmpty else { return }

        let band = try world.graph.lemmaFrequency(db, lemmaId: lemmaId)?.band
        let prior = BKTModel.prior(band: band, parameters: parameters)
        let distinctRegions = try world.graph.distinctRegionCount(db, lemmaId: lemmaId)

        let stream = events.compactMap { row -> (kind: WordEventKind, trust: Double)? in
            guard let kind = WordEventKind(rawValue: row.kind) else { return nil }
            return (kind, row.trust)
        }
        let belief = BKTModel.replay(events: stream, prior: prior,
                                     distinctRegions: distinctRegions,
                                     parameters: parameters)

        try world.registry.upsertComponent(db, MasteryBeliefComponent(
            entityId: lemmaId,
            belief: belief,
            opportunities: events.count,
            lastEventAt: events.last?.occurredAt,
            updatedAt: Date(),
            paramsVersion: parameters.version))
    }
}

/// MasterySystem 的上下文操作。
enum MasteryOp: Sendable {
    /// 重算指定 Lemma 的后验。
    case recompute(lemmaIds: [EntityID])
    /// 全量重算（幂等，启动回填 / 参数版本变更时用）。
    case recomputeAll
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter MasterySystemTests 2>&1 | tail -5`
Expected: 8 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ECS/Systems/MasterySystem.swift \
        Tests/WordRecitingAppTests/ECS/Systems/MasterySystemTests.swift
git commit -m "feat(mastery): MasterySystem 重放事件流算 BKT 后验"
```

---
