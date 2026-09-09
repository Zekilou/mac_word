import XCTest
import GRDB
@testable import WordRecitingApp

/// v6 一次性迁移：把 v4 之前产生的词汇记录（comp_user_known 的 mastery / seen_count）
/// 合成为词事件流，让 BKT 后验对历史数据也有值。
final class LegacyEventBackfillTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func seedKnown(_ lemmaId: String, mastery: Double, seenCount: Int,
                           updatedAt: Date = Date(), band: Int? = nil) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: updatedAt)
        try world.registry.upsertComponent(TextComponent(
            entityId: lemmaId, textA: lemmaId, textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: lemmaId, mastery: mastery, seenCount: seenCount,
            source: "legacy", updatedAt: updatedAt))
        if let band {
            try world.registry.upsertComponent(LemmaFrequencyComponent(
                entityId: lemmaId, band: band, freqRank: 1, source: "test"))
        }
    }

    private func runBackfill() throws {
        try appDB.dbWriter.write { db in try LegacyEventBackfill.run(db) }
    }

    private func events(_ lemmaId: String) throws -> [GraphQueries.WordEventRow] {
        try appDB.dbWriter.read { db in
            try world.graph.wordEvents(db, lemmaId: lemmaId, ascending: true)
        }
    }

    func testMasteredWordGetsMarkKnown() throws {
        try seedKnown("L1", mastery: 2.0, seenCount: 0)
        try runBackfill()

        let events = try events("L1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, "mark_known")
        XCTAssertEqual(events[0].trust, 1.0, accuracy: 0.0001)
    }

    func testUnmasteredWordGetsMarkUnknown() throws {
        try seedKnown("L1", mastery: 1.0, seenCount: 0)
        try runBackfill()

        XCTAssertEqual(try events("L1").map(\.kind), ["mark_unknown"])
    }

    func testSeenOnlyWordGetsSinglePassiveEvent() throws {
        try seedKnown("L1", mastery: 0.0, seenCount: 5)
        try runBackfill()

        let events = try events("L1")
        XCTAssertEqual(events.map(\.kind), ["seen"])
        XCTAssertEqual(events[0].trust, 0.0, accuracy: 0.0001)
    }

    /// 显式标记发生在被动出现之后（时间升序）。
    func testSeenEventPrecedesExplicitMark() throws {
        try seedKnown("L1", mastery: 2.0, seenCount: 3)
        try runBackfill()

        let events = try events("L1")
        XCTAssertEqual(events.map(\.kind), ["seen", "mark_known"])
        XCTAssertLessThan(events[0].occurredAt, events[1].occurredAt)
    }

    /// 学习中值域（1~2）用 trust 表达"半会"：mastery 1.5 → trust 0.5。
    func testLearningBandMapsMasteryToTrust() throws {
        try seedKnown("L1", mastery: 1.5, seenCount: 0)
        try runBackfill()

        let events = try events("L1")
        XCTAssertEqual(events.map(\.kind), ["mark_known"])
        XCTAssertEqual(events[0].trust, 0.5, accuracy: 0.0001)
    }

    func testRegionIsRegisteredAsLegacy() throws {
        try seedKnown("L1", mastery: 2.0, seenCount: 0)
        try runBackfill()

        let region = try world.graph.region(regionId: LegacyEventBackfill.regionId)
        XCTAssertEqual(region?.kind, RegionKind.legacy.rawValue)
        XCTAssertEqual(region?.trust ?? 0, 1.0, accuracy: 0.0001)
    }

    /// 事件节点要有 produces + contains 两条边（与 RegionSystem 写入约定一致）。
    func testEventsCarryGraphEdges() throws {
        try seedKnown("L1", mastery: 2.0, seenCount: 0)
        try runBackfill()

        let edgeCount = try appDB.dbWriter.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM edges WHERE dst_id LIKE 'legacy-we-%'") ?? 0
        }
        XCTAssertEqual(edgeCount, 2)
    }

    func testIdempotent() throws {
        try seedKnown("L1", mastery: 2.0, seenCount: 3)
        try runBackfill()
        try runBackfill()

        XCTAssertEqual(try events("L1").count, 2)
    }

    func testRollbackRemovesEverything() throws {
        try seedKnown("L1", mastery: 2.0, seenCount: 3)
        try runBackfill()

        try appDB.dbWriter.write { db in try LegacyEventBackfill.rollback(db) }

        XCTAssertTrue(try events("L1").isEmpty)
        XCTAssertNil(try world.graph.region(regionId: LegacyEventBackfill.regionId))
        let eventNodes = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nodes WHERE id LIKE 'legacy-we-%'") ?? 0
        }
        XCTAssertEqual(eventNodes, 0)
    }

    /// 回填事件后重算 → 老词也有后验概率（模型主口径可用）。
    func testBeliefRecomputedFromBackfilledEvents() throws {
        try seedKnown("L1", mastery: 2.0, seenCount: 0, band: 2)
        try runBackfill()

        try world.run(MasterySystem(), context: .recomputeAll)

        let belief = try XCTUnwrap(world.graph.masteryBelief(lemmaId: "L1"))
        XCTAssertGreaterThanOrEqual(belief, WordMarkState.knownThreshold)
    }
}
