# Task 7：查询 API（GraphQueries + Region）

**Files:**
- Create: `Sources/WordRecitingApp/ECS/GraphQueries+Region.swift`
- Test: `Tests/WordRecitingAppTests/ECS/GraphQueriesRegionTests.swift`（新建）

**依赖：** Task 4、Task 6。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/GraphQueriesRegionTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class GraphQueriesRegionTests: XCTestCase {
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

    private func record(_ lemmaIds: [EntityID], _ region: RegionRef, _ kind: WordEventKind,
                        trust: Double? = nil) throws {
        try world.run(RegionSystem(), context: .record(
            lemmaIds: lemmaIds, region: region, kind: kind, trust: trust, detail: nil))
    }

    func testWordEventsByLemmaOrderedDesc() throws {
        try makeLemma("L1", "abandon")
        let ref = RegionRef.dictionary()
        try record(["L1"], ref, .lookup)
        try record(["L1"], ref, .markUnknown, trust: 1.0)

        let events = try graph.wordEvents(lemmaId: "L1")
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].occurredAt >= events[1].occurredAt)
    }

    func testWordEventsByRegion() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "ability")
        let ref = RegionRef.rss(articleId: "A1", title: "t")
        try record(["L1", "L2"], ref, .seen)

        XCTAssertEqual(try graph.wordEvents(regionId: ref.id).count, 2)
        XCTAssertEqual(try graph.wordEvents(regionId: "region-missing").count, 0)
    }

    func testEventCountsByKindAndDistinctRegionCount() throws {
        try makeLemma("L1", "abandon")
        try record(["L1"], .rss(articleId: "A1", title: nil), .seen)
        try record(["L1"], .rss(articleId: "A2", title: nil), .seen)
        try record(["L1"], .dictionary(), .markUnknown, trust: 1.0)

        let counts = try graph.wordEventCountsByKind(lemmaId: "L1")
        XCTAssertEqual(counts["seen"], 2)
        XCTAssertEqual(counts["mark_unknown"], 1)
        XCTAssertEqual(try graph.wordEventCount(lemmaId: "L1"), 3)
        XCTAssertEqual(try graph.distinctRegionCount(lemmaId: "L1"), 3)
    }

    func testRegionLookup() throws {
        let ref = RegionRef.study(cardId: "C1")
        try world.run(RegionSystem(), context: .ensure(ref))

        let row = try graph.region(regionId: ref.id)
        XCTAssertEqual(row?.kind, "study")
        XCTAssertEqual(row?.sourceId, "C1")
        XCTAssertEqual(row?.trust, 1.0)
        XCTAssertNil(try graph.region(regionId: "region-missing"))
    }

    func testLemmaFrequencyQueries() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "the")
        let provider = try BundledWordFrequencyProvider(data: Data("""
        {"source":"test","families":[
          {"rank":1,"band":1,"members":["the"]},
          {"rank":1001,"band":2,"members":["abandon"]}
        ]}
        """.utf8))
        try world.run(LemmaFrequencySystem(provider: provider), context: .stampAll)

        XCTAssertEqual(try graph.lemmaFrequency(lemmaId: "L1")?.band, 2)
        XCTAssertEqual(try graph.lemmaFrequency(lemmaId: "L1")?.freqRank, 1001)
        XCTAssertNil(try graph.lemmaFrequency(lemmaId: "missing"))
        XCTAssertEqual(try graph.allLemmaFrequencies().count, 2)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GraphQueriesRegionTests 2>&1 | tail -5`
Expected: FAIL（`value of type 'GraphQueries' has no member 'wordEvents'`）。

- [ ] **Step 3: 实现**

新建 `Sources/WordRecitingApp/ECS/GraphQueries+Region.swift`：

```swift
import Foundation
import GRDB

/// GraphQueries 扩展：region / 词事件 / 词频坐标查询。
/// @ai: 业务代码禁止手写 SQL，必须走本扩展的命名方法。
extension GraphQueries {

    /// 一条词事件（时间倒序返回）。
    struct WordEventRow: Sendable, Equatable, Identifiable {
        var id: EntityID { eventId }
        let eventId: EntityID
        let lemmaId: EntityID
        let regionId: EntityID
        /// WordEventKind.rawValue。
        let kind: String
        let trust: Double
        let occurredAt: Date
    }

    /// 一个词汇显示上下文。
    struct RegionRow: Sendable, Equatable, Identifiable {
        var id: EntityID { regionId }
        let regionId: EntityID
        /// RegionKind.rawValue。
        let kind: String
        let label: String?
        let sourceId: EntityID?
        let trust: Double
        let createdAt: Date
    }

    /// 词频族坐标。
    struct LemmaFrequencyRow: Sendable, Equatable {
        let band: Int
        let freqRank: Int
        let source: String
    }

    // MARK: - 词事件

    /// 某 Lemma 的全部词事件（时间倒序）。
    func wordEvents(lemmaId: EntityID, limit: Int = 500) throws -> [WordEventRow] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, lemma_id, region_id, event_kind, trust, occurred_at
                FROM comp_word_event
                WHERE lemma_id = ?
                ORDER BY occurred_at DESC, entity_id DESC
                LIMIT ?
                """, arguments: [lemmaId, limit])
            return rows.map(Self.makeEventRow)
        }
    }

    /// 某 Region 内的全部词事件（时间倒序）。
    func wordEvents(regionId: EntityID, limit: Int = 500) throws -> [WordEventRow] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, lemma_id, region_id, event_kind, trust, occurred_at
                FROM comp_word_event
                WHERE region_id = ?
                ORDER BY occurred_at DESC, entity_id DESC
                LIMIT ?
                """, arguments: [regionId, limit])
            return rows.map(Self.makeEventRow)
        }
    }

    /// 某 Lemma 的事件总数。
    func wordEventCount(lemmaId: EntityID) throws -> Int {
        try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_word_event WHERE lemma_id = ?",
                             arguments: [lemmaId]) ?? 0
        }
    }

    /// 某 Lemma 按事件种类分组计数（后续 BKT / CD 建模的输入）。
    func wordEventCountsByKind(lemmaId: EntityID) throws -> [String: Int] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT event_kind, COUNT(*) AS n
                FROM comp_word_event
                WHERE lemma_id = ?
                GROUP BY event_kind
                """, arguments: [lemmaId])
            var result: [String: Int] = [:]
            for row in rows { result[row["event_kind"]] = row["n"] }
            return result
        }
    }

    /// 某 Lemma 出现在多少个不同 region（上下文多样性 CD 的原始量）。
    func distinctRegionCount(lemmaId: EntityID) throws -> Int {
        try database.dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT region_id) FROM comp_word_event WHERE lemma_id = ?
                """, arguments: [lemmaId]) ?? 0
        }
    }

    // MARK: - Region

    func region(regionId: EntityID) throws -> RegionRow? {
        try database.dbWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT entity_id, kind, label, source_id, trust, created_at
                FROM comp_region
                WHERE entity_id = ?
                """, arguments: [regionId]) else { return nil }
            return RegionRow(regionId: row["entity_id"], kind: row["kind"], label: row["label"],
                             sourceId: row["source_id"], trust: row["trust"],
                             createdAt: row["created_at"])
        }
    }

    // MARK: - 词频坐标

    func lemmaFrequency(lemmaId: EntityID) throws -> LemmaFrequencyRow? {
        try database.dbWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT band, freq_rank, source FROM comp_lemma_frequency WHERE entity_id = ?
                """, arguments: [lemmaId]) else { return nil }
            return LemmaFrequencyRow(band: row["band"], freqRank: row["freq_rank"],
                                     source: row["source"])
        }
    }

    /// 全部词频坐标（批量，供列表展示）。
    func allLemmaFrequencies() throws -> [EntityID: LemmaFrequencyRow] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entity_id, band, freq_rank, source FROM comp_lemma_frequency
                """)
            var result: [EntityID: LemmaFrequencyRow] = [:]
            for row in rows {
                result[row["entity_id"]] = LemmaFrequencyRow(
                    band: row["band"], freqRank: row["freq_rank"], source: row["source"])
            }
            return result
        }
    }

    private static func makeEventRow(_ row: Row) -> WordEventRow {
        WordEventRow(eventId: row["entity_id"], lemmaId: row["lemma_id"],
                     regionId: row["region_id"], kind: row["event_kind"],
                     trust: row["trust"], occurredAt: row["occurred_at"])
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GraphQueriesRegionTests 2>&1 | tail -5`
Expected: 5 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/ECS/GraphQueries+Region.swift \
        Tests/WordRecitingAppTests/ECS/GraphQueriesRegionTests.swift
git commit -m "feat(ecs): GraphQueries 增加 region/事件/词频查询"
```

---
