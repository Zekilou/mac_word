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
