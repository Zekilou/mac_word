import XCTest
@testable import WordRecitingApp

/// 阶段一：region / 词事件 / 词频组件的 round-trip 与注册表登记。
final class RegionComponentsTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry { world.registry }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    func testTableNameMapRegistersNewComponents() {
        XCTAssertEqual(EntityRegistry.tableNameMap[.region], "comp_region")
        XCTAssertEqual(EntityRegistry.tableNameMap[.wordEvent], "comp_word_event")
        XCTAssertEqual(EntityRegistry.tableNameMap[.lemmaFrequency], "comp_lemma_frequency")
    }

    func testRegionComponentRoundTrip() throws {
        try registry.insertNode(id: "R1", kind: .region, createdAt: Date())
        try registry.upsertComponent(RegionComponent(
            entityId: "R1", kind: RegionKind.rss.rawValue, label: "一篇文章",
            sourceId: "A1", trust: 0, createdAt: Date()))

        let back: RegionComponent? = try registry.fetchComponents(for: "R1", table: "comp_region")
        XCTAssertEqual(back?.kind, "rss")
        XCTAssertEqual(back?.label, "一篇文章")
        XCTAssertEqual(back?.sourceId, "A1")
        XCTAssertEqual(back?.trust, 0)
    }

    func testWordEventComponentRoundTrip() throws {
        let now = Date()
        try registry.insertNode(id: "E1", kind: .event, createdAt: now)
        try registry.upsertComponent(WordEventComponent(
            entityId: "E1", lemmaId: "L1", regionId: "R1",
            eventKind: WordEventKind.markUnknown.rawValue, trust: 1,
            occurredAt: now, detailJson: #"{"surface":"abandoned"}"#))

        let back: WordEventComponent? = try registry.fetchComponents(for: "E1", table: "comp_word_event")
        XCTAssertEqual(back?.lemmaId, "L1")
        XCTAssertEqual(back?.regionId, "R1")
        XCTAssertEqual(back?.eventKind, "mark_unknown")
        XCTAssertEqual(back?.trust, 1)
        XCTAssertEqual(back?.detailJson, #"{"surface":"abandoned"}"#)
    }

    func testLemmaFrequencyComponentRoundTrip() throws {
        try registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "bnc-coca-25k"))

        let back: LemmaFrequencyComponent? = try registry.fetchComponents(
            for: "L1", table: "comp_lemma_frequency")
        XCTAssertEqual(back?.band, 2)
        XCTAssertEqual(back?.freqRank, 1001)
        XCTAssertEqual(back?.source, "bnc-coca-25k")
    }
}
