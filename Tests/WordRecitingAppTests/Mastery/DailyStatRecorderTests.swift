import XCTest
import GRDB
@testable import WordRecitingApp

/// 一期：每日统计快照（趋势数据源）。
/// 口径：与概率主口径一致（`WordMarkState` 阈值），单遍重放 `comp_word_event` 得到每天收盘状态。
final class DailyStatRecorderTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private let cal = Calendar.current

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    // MARK: - 夹具

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func seedLemma(_ id: String, band: Int? = nil) throws {
        try world.registry.insertNode(id: id, kind: .lemma, createdAt: day(2026, 1, 1))
        try world.registry.upsertComponent(TextComponent(
            entityId: id, textA: id, textB: nil, language: nil))
        if let band {
            try world.registry.upsertComponent(LemmaFrequencyComponent(
                entityId: id, band: band, freqRank: 1, source: "test"))
        }
    }

    private func insertEvent(_ id: String, lemma: String, kind: WordEventKind,
                             trust: Double = 1.0, at date: Date,
                             region: String = "r1") throws {
        try appDB.dbWriter.write { db in
            try world.registry.insertNode(db, id: id, kind: .event, createdAt: date)
            try db.execute(sql: """
                INSERT INTO comp_word_event
                    (entity_id, lemma_id, region_id, event_kind, trust, occurred_at, detail_json)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """, arguments: [id, lemma, region, kind.rawValue, trust, date])
        }
    }

    private func insertReview(_ id: String, rating: Rating, at date: Date) throws {
        try appDB.dbWriter.write { db in
            try world.registry.insertNode(db, id: id, kind: .event, createdAt: date)
            try db.execute(sql: """
                INSERT INTO comp_review_event (entity_id, rated_at, rating)
                VALUES (?, ?, ?)
                """, arguments: [id, date, rating.rawValue])
        }
    }

    @discardableResult
    private func rebuild(today: Date? = nil) throws -> [DailyStat] {
        try DailyStatRecorder.rebuild(world: world, now: today ?? day(2026, 3, 1))
    }

    // MARK: - 合同

    func testTierThresholdsFollowWordMarkState() {
        XCTAssertEqual(DailyStatRecorder.knownThreshold, WordMarkState.knownThreshold)
        XCTAssertEqual(DailyStatRecorder.unknownThreshold, WordMarkState.unknownThreshold)
    }

    // MARK: - 逐日切分

    func testEmitsSnapshotPerActiveDay() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .seen, trust: 0, at: day(2026, 1, 1))
        try insertEvent("e2", lemma: "L1", kind: .markKnown, trust: 1, at: day(2026, 1, 2))
        try insertEvent("e3", lemma: "L1", kind: .markUnknown, trust: 1, at: day(2026, 1, 3))

        let stats = try rebuild(today: day(2026, 1, 3))

        XCTAssertEqual(stats.map(\.date), ["2026-01-01", "2026-01-02", "2026-01-03"])
        XCTAssertEqual(stats.map(\.events), [1, 1, 1])
    }

    func testNewWordsCountedOnFirstEventDay() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .seen, trust: 0, at: day(2026, 1, 1))
        try insertEvent("e2", lemma: "L1", kind: .seen, trust: 0, at: day(2026, 1, 2))
        try seedLemma("L2", band: 2)
        try insertEvent("e3", lemma: "L2", kind: .seen, trust: 0, at: day(2026, 1, 2))

        let stats = try rebuild(today: day(2026, 1, 2))

        XCTAssertEqual(stats.map(\.newWords), [1, 1])
    }

    func testKnownByBandBuckets() throws {
        try seedLemma("L1", band: 2)
        try seedLemma("L2", band: 2)
        try seedLemma("L3", band: 7)
        try insertEvent("e1", lemma: "L1", kind: .markKnown, trust: 1, at: day(2026, 1, 1))
        try insertEvent("e2", lemma: "L2", kind: .markKnown, trust: 1, at: day(2026, 1, 1))
        try insertEvent("e3", lemma: "L3", kind: .markUnknown, trust: 1, at: day(2026, 1, 1))

        let stat = try XCTUnwrap(try rebuild(today: day(2026, 1, 1)).last)

        XCTAssertEqual(stat.knownByBand["2"], 2)
        XCTAssertNil(stat.knownByBand["7"])
    }

    // MARK: - 与实时口径一致

    func testLastSnapshotMatchesLiveDistribution() throws {
        try seedLemma("known", band: 2)
        try seedLemma("unknown", band: 20)
        try insertEvent("e1", lemma: "known", kind: .markKnown, trust: 1, at: day(2026, 1, 1))
        try insertEvent("e2", lemma: "unknown", kind: .markUnknown, trust: 1, at: day(2026, 1, 1))

        let stats = try rebuild(today: day(2026, 1, 1))
        let last = try XCTUnwrap(stats.last)

        try world.run(MasterySystem(), context: .recomputeAll)
        let live = try world.graph.masteryDistribution(
            knownThreshold: WordMarkState.knownThreshold,
            unknownThreshold: WordMarkState.unknownThreshold)

        XCTAssertEqual(last.known, live.known)
        XCTAssertEqual(last.learning, live.learning)
        XCTAssertEqual(last.unknown, live.unknown)
        XCTAssertEqual(last.observed, live.total)
    }

    // MARK: - 复习与记忆质量

    func testReviewStatsAndRetention() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .seen, trust: 0, at: day(2026, 1, 1))
        try insertReview("r1", rating: .good, at: day(2026, 1, 1))
        try insertReview("r2", rating: .easy, at: day(2026, 1, 1))
        try insertReview("r3", rating: .again, at: day(2026, 1, 2))

        let stats = try rebuild(today: day(2026, 1, 2))
        let d1 = try XCTUnwrap(stats.first { $0.date == "2026-01-01" })
        let d2 = try XCTUnwrap(stats.first { $0.date == "2026-01-02" })

        XCTAssertEqual(d1.reviews, 2)
        XCTAssertEqual(d1.retention ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(d2.reviews, 1)
        XCTAssertEqual(d2.retention ?? 1, 0.0, accuracy: 0.0001)
    }

    func testReviewOnlyDayCarriesForwardBelief() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .markKnown, trust: 1, at: day(2026, 1, 1))
        try insertReview("r1", rating: .good, at: day(2026, 1, 3))

        let stats = try rebuild(today: day(2026, 1, 3))

        XCTAssertEqual(stats.map(\.date), ["2026-01-01", "2026-01-03"])
        let last = try XCTUnwrap(stats.last)
        XCTAssertEqual(last.events, 0)
        XCTAssertEqual(last.reviews, 1)
        XCTAssertEqual(last.known, stats.first?.known)
    }

    // MARK: - 今日快照

    func testTodaySnapshotAlwaysPresent() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .markKnown, trust: 1, at: day(2026, 1, 1))

        let stats = try rebuild(today: day(2026, 2, 1))

        XCTAssertEqual(stats.map(\.date), ["2026-01-01", "2026-02-01"])
        XCTAssertEqual(stats.last?.events, 0)
        XCTAssertEqual(stats.last?.known, 1)
    }

    // MARK: - 幂等与持久化

    func testRebuildIsIdempotent() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .seen, trust: 0, at: day(2026, 1, 1))

        let first = try rebuild(today: day(2026, 1, 2))
        let second = try rebuild(today: day(2026, 1, 2))

        XCTAssertEqual(first, second)
        let nodeCount = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nodes WHERE kind = 'analytics_day'") ?? 0
        }
        XCTAssertEqual(nodeCount, second.count)
    }

    func testStaleSnapshotsRemovedOnRebuild() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .seen, trust: 0, at: day(2026, 1, 1))
        XCTAssertEqual(try rebuild(today: day(2026, 1, 1)).count, 1)

        try world.registry.deleteNode(id: "e1")

        XCTAssertTrue(try rebuild(today: day(2026, 1, 1)).isEmpty)
    }

    func testSnapshotStoredInAnalyticsCache() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .markKnown, trust: 1, at: day(2026, 1, 1))

        let stats = try rebuild(today: day(2026, 1, 1))
        let stat = try XCTUnwrap(stats.first)
        let row = try appDB.dbWriter.read { db in
            try Row.fetchOne(db, sql: """
                SELECT module_id, scope_hash, payload_json FROM comp_analytics_cache
                WHERE entity_id = ?
                """, arguments: [DailyStatRecorder.nodeId(date: stat.date)])
        }
        let unwrapped = try XCTUnwrap(row)
        XCTAssertEqual(unwrapped["module_id"], DailyStatRecorder.moduleId)
        XCTAssertEqual(unwrapped["scope_hash"], stat.date)
        let payload: String = unwrapped["payload_json"]
        let decoded = try JSONDecoder().decode(DailyStat.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded, stat)
    }

    func testLoadAllReturnsAscending() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .seen, trust: 0, at: day(2026, 1, 3))
        try insertEvent("e2", lemma: "L1", kind: .seen, trust: 0, at: day(2026, 1, 1))

        let rebuilt = try rebuild(today: day(2026, 1, 3))
        let loaded = try DailyStatRecorder.loadAll(world: world)

        XCTAssertEqual(loaded.map(\.date), ["2026-01-01", "2026-01-03"])
        XCTAssertEqual(loaded, rebuilt.sorted { $0.date < $1.date })
    }

    func testEmptyDatabaseEmitsNothing() throws {
        XCTAssertTrue(try rebuild(today: day(2026, 1, 1)).isEmpty)
        XCTAssertTrue(try DailyStatRecorder.loadAll(world: world).isEmpty)
    }

    /// 词汇量估算随日快照一起落库（供能力画像的趋势线）。
    func testEstimatedFamiliesIsPopulated() throws {
        try seedLemma("L1", band: 2)
        try insertEvent("e1", lemma: "L1", kind: .markKnown, trust: 1, at: day(2026, 1, 1))

        let stat = try XCTUnwrap(try rebuild(today: day(2026, 1, 1)).last)

        XCTAssertGreaterThan(stat.estimatedFamilies ?? 0, 0.8)
    }
}
