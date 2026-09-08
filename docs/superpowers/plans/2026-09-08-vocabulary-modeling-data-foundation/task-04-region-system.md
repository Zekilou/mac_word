# Task 4：RegionSystem（region 幂等 + 全量词事件）

**Files:**
- Create: `Sources/WordRecitingApp/ECS/Systems/RegionSystem.swift`
- Test: `Tests/WordRecitingAppTests/ECS/Systems/RegionSystemTests.swift`（新建）

**依赖：** Task 3。

**设计：** 一次 `record` = 确保 region 存在 → 为每个 lemma 写一个事件节点 + `comp_word_event` + 两条边：
- `lemma --produces--> event`
- `region --contains--> event`

事件级可信度 = `override ?? region.trust`。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/Systems/RegionSystemTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class RegionSystemTests: XCTestCase {
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

    private func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args)
        } ?? 0
    }

    // MARK: - region

    func testEnsureIsIdempotent() throws {
        let ref = RegionRef.dictionary()
        try world.run(RegionSystem(), context: .ensure(ref))
        try world.run(RegionSystem(), context: .ensure(ref))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'region'"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_region"), 1)
        XCTAssertEqual(try count("SELECT trust FROM comp_region WHERE entity_id = ?", [ref.id]), 1)
    }

    func testRegionRefFactories() {
        XCTAssertEqual(RegionRef.study(cardId: "C1").trust, 1.0)
        XCTAssertEqual(RegionRef.dictionary().trust, 1.0)
        XCTAssertEqual(RegionRef.initSession(sessionId: "S1").trust, 1.0)
        XCTAssertEqual(RegionRef.rss(articleId: "A1", title: "t").trust, 0.0)
        XCTAssertEqual(RegionRef.generate(articleId: "A1", title: nil).trust, 0.0)
    }

    // MARK: - 事件

    func testRecordCreatesEventAndEdges() throws {
        try makeLemma("L1", "abandon")
        let ref = RegionRef.study(cardId: "C1")

        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: ref, kind: .quizWrong, trust: nil, detail: nil))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE lemma_id = ? AND region_id = ? AND event_kind = 'quiz_wrong'",
            ["L1", ref.id]), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM edges WHERE src_id = ? AND rel_type = 'produces'", ["L1"]), 1)
        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM edges WHERE src_id = ? AND rel_type = 'contains'", [ref.id]), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM nodes WHERE kind = 'event'"), 1)
    }

    func testEventTrustInheritsRegionWhenNoOverride() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .rss(articleId: "A1", title: nil),
            kind: .seen, trust: nil, detail: nil))

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE trust = 0"), 1)
    }

    func testEventTrustOverrideForActiveInteractionInPassiveRegion() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .rss(articleId: "A1", title: nil),
            kind: .markUnknown, trust: 1.0, detail: nil))

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE trust = 1"), 1)
    }

    func testRecordManyAndSkipUnknownLemma() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "ability")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1", "L2", "L404"], region: .dictionary(),
            kind: .lookup, trust: nil, detail: nil))

        XCTAssertEqual(try count("SELECT COUNT(*) FROM comp_word_event"), 2)
    }

    func testRecordKeepsDetailJson() throws {
        try makeLemma("L1", "abandon")
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .generate(articleId: "A1", title: nil),
            kind: .seen, trust: nil, detail: #"{"surface":"abandoned"}"#))

        XCTAssertEqual(try count(
            "SELECT COUNT(*) FROM comp_word_event WHERE detail_json = ?",
            [#"{"surface":"abandoned"}"#]), 1)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RegionSystemTests 2>&1 | tail -5`
Expected: FAIL（`cannot find 'RegionSystem' in scope`）。

- [ ] **Step 3: 实现**

新建 `Sources/WordRecitingApp/ECS/Systems/RegionSystem.swift`：

```swift
import Foundation
import GRDB

/// RegionSystem：管理「显示词汇的上下文」并全量记录词事件。
/// @ai: 一次 record 会先幂等 upsert region，再为每个 lemma 落一个事件节点 + 组件 + 两条边。
///      event.trust = override ?? region.trust —— 被动 region 内的主动交互可提升可信度。
struct RegionSystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = RegionOp

    func execute(world: World, db: Database, entities: [EntityID], context: RegionOp) throws {
        switch context {
        case .ensure(let ref):
            try ensureRegion(world: world, db: db, ref: ref)

        case .record(let lemmaIds, let ref, let kind, let override, let detail):
            try ensureRegion(world: world, db: db, ref: ref)
            let now = Date()
            let trust = override ?? ref.trust
            for lemmaId in lemmaIds {
                guard try world.registry.fetchNode(db, id: lemmaId) != nil else { continue }
                let eventId = "word-event-\(UUID().uuidString)"
                try world.registry.insertNode(db, id: eventId, kind: .event, createdAt: now)
                try world.registry.upsertComponent(db, WordEventComponent(
                    entityId: eventId,
                    lemmaId: lemmaId,
                    regionId: ref.id,
                    eventKind: kind.rawValue,
                    trust: trust,
                    occurredAt: now,
                    detailJson: detail))
                try world.registry.insertEdge(db, id: "we-lemma-\(eventId)",
                                              srcId: lemmaId, dstId: eventId,
                                              rel: .produces, createdAt: now)
                try world.registry.insertEdge(db, id: "we-region-\(eventId)",
                                              srcId: ref.id, dstId: eventId,
                                              rel: .contains, createdAt: now)
            }
        }
    }

    /// 幂等：region 节点不存在才建；组件始终按最新描述覆盖。
    private func ensureRegion(world: World, db: Database, ref: RegionRef) throws {
        if try world.registry.fetchNode(db, id: ref.id) == nil {
            try world.registry.insertNode(db, id: ref.id, kind: .region, createdAt: Date())
        }
        try world.registry.upsertComponent(db, RegionComponent(
            entityId: ref.id,
            kind: ref.kind.rawValue,
            label: ref.label,
            sourceId: ref.sourceId,
            trust: ref.trust,
            createdAt: Date()))
    }
}

/// Region 引用描述。id 由业务键构造，保证同一上下文复用同一 region。
struct RegionRef: Sendable, Equatable {
    let id: EntityID
    let kind: RegionKind
    let label: String?
    let sourceId: EntityID?
    /// 该上下文的基础可信度：主动上下文 1.0，被动上下文 0.0。
    let trust: Double

    static func study(cardId: EntityID) -> RegionRef {
        RegionRef(id: "region-study-\(cardId)", kind: .study,
                  label: nil, sourceId: cardId, trust: 1.0)
    }

    static func rss(articleId: EntityID, title: String?) -> RegionRef {
        RegionRef(id: "region-rss-\(articleId)", kind: .rss,
                  label: title, sourceId: articleId, trust: 0.0)
    }

    static func generate(articleId: EntityID, title: String?) -> RegionRef {
        RegionRef(id: "region-generate-\(articleId)", kind: .generate,
                  label: title, sourceId: articleId, trust: 0.0)
    }

    static func dictionary() -> RegionRef {
        RegionRef(id: "region-dictionary", kind: .dictionary,
                  label: nil, sourceId: nil, trust: 1.0)
    }

    static func initSession(sessionId: EntityID) -> RegionRef {
        RegionRef(id: "region-init-\(sessionId)", kind: .initSession,
                  label: nil, sourceId: sessionId, trust: 1.0)
    }
}

/// RegionSystem 的上下文操作。
enum RegionOp: Sendable {
    /// 仅确保 region 存在（例如进入页面时先登记）。
    case ensure(RegionRef)
    /// 记录一次/一批词事件；`trust` 非 nil 时覆盖 region 基础可信度。
    case record(lemmaIds: [EntityID], region: RegionRef,
                kind: WordEventKind, trust: Double?, detail: String?)
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RegionSystemTests 2>&1 | tail -5`
Expected: 7 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ECS/Systems/RegionSystem.swift \
        Tests/WordRecitingAppTests/ECS/Systems/RegionSystemTests.swift
git commit -m "feat(ecs): RegionSystem 落 region 与全量词事件"
```

---
