# Task 1：特征层 `WordFeatures` + 查询

**Files:**
- Create: `Sources/WordRecitingApp/Scheduling/WordFeatures.swift`
- Create: `Sources/WordRecitingApp/ECS/GraphQueries+Features.swift`
- Test: `Tests/WordRecitingAppTests/ECS/GraphQueriesFeaturesTests.swift`（新建）

**依赖：** 无（阶段二/三的 `comp_mastery_belief`、`comp_lemma_frequency`、`comp_word_event` 已存在）。

**目标：** 一次查询把一个词元决策所需的全部特征拿全——词频坐标、BKT 后验、事件流聚合、卡片调度。**N 个词只跑 1 条 SQL。**

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/GraphQueriesFeaturesTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class GraphQueriesFeaturesTests: XCTestCase {
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

    func testFeaturesCombineBeliefFrequencyEventsAndCard() throws {
        let now = Date()
        try makeLemma("L1", "abandon")
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.62, opportunities: 3,
            lastEventAt: now, updatedAt: now, paramsVersion: "bkt-1"))
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "test"))
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .lookup, trust: 1.0, detail: nil))
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .rss(articleId: "A1", title: nil),
            kind: .seen, trust: 0.0, detail: nil))

        try world.registry.insertNode(id: "C1", kind: .card, createdAt: now)
        try world.registry.insertEdge(id: "edge-C1", srcId: "C1", dstId: "L1",
                                      rel: .instantiates, createdAt: now)
        try world.registry.upsertComponent(ScheduleStateComponent(
            entityId: "C1", stability: 3, difficulty: 2.5,
            dueAt: now.addingTimeInterval(86400), intervalDays: 3,
            reps: 2, lapses: 0, lastRating: 3, lastReviewedAt: now,
            schedulerId: "sm-2", queue: "review", customDataJson: nil))

        let features = try XCTUnwrap(try graph.wordFeatures(lemmaIds: ["L1"])["L1"])

        XCTAssertEqual(features.lemmaId, "L1")
        XCTAssertEqual(features.belief ?? 0, 0.62, accuracy: 0.0001)
        XCTAssertEqual(features.band, 2)
        XCTAssertEqual(features.rank, 1001)
        XCTAssertEqual(features.eventCount, 2)
        XCTAssertEqual(features.contextCount, 2)
        XCTAssertNotNil(features.lastEventAt)
        XCTAssertEqual(features.card?.cardId, "C1")
        XCTAssertEqual(features.card?.reps, 2)
        XCTAssertEqual(features.card?.intervalDays ?? 0, 3, accuracy: 0.0001)
    }

    func testFeaturesWithoutCardAndWithoutData() throws {
        try makeLemma("L2", "ability")

        let features = try XCTUnwrap(try graph.wordFeatures(lemmaIds: ["L2"])["L2"])

        XCTAssertNil(features.belief)
        XCTAssertNil(features.band)
        XCTAssertNil(features.card)
        XCTAssertEqual(features.eventCount, 0)
        XCTAssertEqual(features.contextCount, 0)
    }

    func testBatchLookupReturnsOnlyRequestedLemmas() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "ability")
        try makeLemma("L3", "zebra")

        let result = try graph.wordFeatures(lemmaIds: ["L1", "L3"])

        XCTAssertEqual(Set(result.keys), ["L1", "L3"])
    }

    func testEmptyIdsReturnsEmpty() throws {
        XCTAssertTrue(try graph.wordFeatures(lemmaIds: []).isEmpty)
    }

    func testDbVersionWorksInsideWriteTransaction() throws {
        try makeLemma("L1", "abandon")

        try appDB.dbWriter.write { db in
            let result = try self.graph.wordFeatures(db, lemmaIds: ["L1"])
            XCTAssertNotNil(result["L1"])
        }
    }

    func testAllWordFeaturesCoversEveryLemma() throws {
        try makeLemma("L1", "abandon")
        try makeLemma("L2", "ability")

        XCTAssertEqual(try graph.allWordFeatures().count, 2)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GraphQueriesFeaturesTests 2>&1 | tail -8`
Expected: FAIL（`cannot find 'WordFeatures' in scope` / `no member 'wordFeatures'`）。

- [ ] **Step 3: 实现**

**3a. 新建 `Sources/WordRecitingApp/Scheduling/WordFeatures.swift`：**

```swift
import Foundation

/// 一个词元在决策时需要的全部特征（词频 + 概率 + 事件流 + 卡片调度）。
/// @ai: 纯值类型，策略只消费它、不碰数据库。
struct WordFeatures: Sendable, Equatable {
    let lemmaId: EntityID
    /// BKT 后验概率；nil = 尚无事件。
    let belief: Double?
    /// 词频带 1..25；nil = 无坐标（词表外或词表未加载）。
    let band: Int?
    /// 全表排名。
    let rank: Int?
    /// 词事件总数。
    let eventCount: Int
    /// 不同 region 数（上下文多样性 CD）。
    let contextCount: Int
    /// 最近一次事件时间。
    let lastEventAt: Date?
    /// 卡片调度状态；无卡 = nil。
    let card: CardSchedule?

    /// 卡片调度状态（一个 Lemma 只取一张卡）。
    struct CardSchedule: Sendable, Equatable {
        let cardId: EntityID
        let dueAt: Date?
        let reps: Int
        let lapses: Int
        let intervalDays: Double?
        /// 上次复习时间；「实际经过天数」= now − lastReviewedAt，由策略自算（不额外查库）。
        let lastReviewedAt: Date?
    }
}
```

**3b. 新建 `Sources/WordRecitingApp/ECS/GraphQueries+Features.swift`：**

```swift
import Foundation
import GRDB

/// GraphQueries 扩展：词元特征批量查询（调度策略的数据来源）。
/// @ai: 一次 SQL 拿全；N 个词不产生 N 次查询。业务代码禁止手写 SQL，走这里。
extension GraphQueries {

    /// db 版本：批量取词元特征（复用外层事务）。
    func wordFeatures(_ db: Database, lemmaIds: [EntityID]) throws -> [EntityID: WordFeatures] {
        guard !lemmaIds.isEmpty else { return [:] }
        let placeholders = databaseQuestionMarks(count: lemmaIds.count)
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                n.id                        AS lemma_id,
                b.belief                    AS belief,
                f.band                      AS band,
                f.freq_rank                 AS freq_rank,
                COALESCE(ev.event_count, 0)   AS event_count,
                COALESCE(ev.context_count, 0) AS context_count,
                ev.last_event_at            AS last_event_at,
                c.card_id                   AS card_id,
                ss.due_at                   AS due_at,
                ss.reps                     AS reps,
                ss.lapses                   AS lapses,
                ss.interval_days            AS interval_days,
                ss.last_reviewed_at         AS last_reviewed_at
            FROM nodes n
            LEFT JOIN comp_mastery_belief  b ON b.entity_id = n.id
            LEFT JOIN comp_lemma_frequency f ON f.entity_id = n.id
            LEFT JOIN (
                SELECT lemma_id,
                       COUNT(*)                  AS event_count,
                       COUNT(DISTINCT region_id) AS context_count,
                       MAX(occurred_at)          AS last_event_at
                FROM comp_word_event
                GROUP BY lemma_id
            ) ev ON ev.lemma_id = n.id
            LEFT JOIN (
                SELECT inst.dst_id AS lemma_id, MIN(card.id) AS card_id
                FROM edges inst
                JOIN nodes card ON card.id = inst.src_id AND card.kind = 'card'
                WHERE inst.rel_type = 'instantiates'
                GROUP BY inst.dst_id
            ) c ON c.lemma_id = n.id
            LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.card_id
            WHERE n.kind = 'lemma' AND n.id IN (\(placeholders))
            """, arguments: StatementArguments(lemmaIds))
        return Self.mapFeatures(rows)
    }

    /// 便捷版本：自开读事务。
    func wordFeatures(lemmaIds: [EntityID]) throws -> [EntityID: WordFeatures] {
        try database.dbWriter.read { db in
            try self.wordFeatures(db, lemmaIds: lemmaIds)
        }
    }

    /// db 版本：全部 Lemma 的特征。
    func allWordFeatures(_ db: Database) throws -> [EntityID: WordFeatures] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                n.id                        AS lemma_id,
                b.belief                    AS belief,
                f.band                      AS band,
                f.freq_rank                 AS freq_rank,
                COALESCE(ev.event_count, 0)   AS event_count,
                COALESCE(ev.context_count, 0) AS context_count,
                ev.last_event_at            AS last_event_at,
                c.card_id                   AS card_id,
                ss.due_at                   AS due_at,
                ss.reps                     AS reps,
                ss.lapses                   AS lapses,
                ss.interval_days            AS interval_days,
                ss.last_reviewed_at         AS last_reviewed_at
            FROM nodes n
            LEFT JOIN comp_mastery_belief  b ON b.entity_id = n.id
            LEFT JOIN comp_lemma_frequency f ON f.entity_id = n.id
            LEFT JOIN (
                SELECT lemma_id,
                       COUNT(*)                  AS event_count,
                       COUNT(DISTINCT region_id) AS context_count,
                       MAX(occurred_at)          AS last_event_at
                FROM comp_word_event
                GROUP BY lemma_id
            ) ev ON ev.lemma_id = n.id
            LEFT JOIN (
                SELECT inst.dst_id AS lemma_id, MIN(card.id) AS card_id
                FROM edges inst
                JOIN nodes card ON card.id = inst.src_id AND card.kind = 'card'
                WHERE inst.rel_type = 'instantiates'
                GROUP BY inst.dst_id
            ) c ON c.lemma_id = n.id
            LEFT JOIN comp_schedule_state ss ON ss.entity_id = c.card_id
            WHERE n.kind = 'lemma'
            """)
        return Self.mapFeatures(rows)
    }

    /// 便捷版本：自开读事务。
    func allWordFeatures() throws -> [EntityID: WordFeatures] {
        try database.dbWriter.read { db in
            try self.allWordFeatures(db)
        }
    }

    private static func mapFeatures(_ rows: [Row]) -> [EntityID: WordFeatures] {
        var result: [EntityID: WordFeatures] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let lemmaId: EntityID = row["lemma_id"]
            let cardId: EntityID? = row["card_id"]
            result[lemmaId] = WordFeatures(
                lemmaId: lemmaId,
                belief: row["belief"],
                band: row["band"],
                rank: row["freq_rank"],
                eventCount: row["event_count"] ?? 0,
                contextCount: row["context_count"] ?? 0,
                lastEventAt: row["last_event_at"],
                card: cardId.map { id in
                    WordFeatures.CardSchedule(
                        cardId: id,
                        dueAt: row["due_at"],
                        reps: row["reps"] ?? 0,
                        lapses: row["lapses"] ?? 0,
                        intervalDays: row["interval_days"],
                        lastReviewedAt: row["last_reviewed_at"])
                })
        }
        return result
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GraphQueriesFeaturesTests 2>&1 | tail -8`
Expected: 6 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/Scheduling/WordFeatures.swift \
        Sources/WordRecitingApp/ECS/GraphQueries+Features.swift \
        Tests/WordRecitingAppTests/ECS/GraphQueriesFeaturesTests.swift
git commit -m "feat(scheduling): 词元特征层（一次查全概率/词频/事件/卡片）"
```

---
