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
