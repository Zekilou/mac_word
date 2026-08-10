import XCTest
@testable import WordRecitingApp

final class AppTypesTests: XCTestCase {

    // MARK: - NodeKind

    func testNodeKindRawValues() {
        XCTAssertEqual(NodeKind.lemma.rawValue, "lemma")
        XCTAssertEqual(NodeKind.card.rawValue, "card")
        XCTAssertEqual(NodeKind.deck.rawValue, "deck")
        XCTAssertEqual(NodeKind.sentence.rawValue, "sentence")
        XCTAssertEqual(NodeKind.article.rawValue, "article")
        XCTAssertEqual(NodeKind.event.rawValue, "event")
        XCTAssertEqual(NodeKind.edge.rawValue, "edge")
    }

    func testNodeKindRoundTrip() throws {
        for kind in [NodeKind.lemma, .card, .deck, .sentence, .article, .event, .edge] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(NodeKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // MARK: - EdgeRel

    func testEdgeRelRawValues() {
        XCTAssertEqual(EdgeRel.has.rawValue, "has")
        XCTAssertEqual(EdgeRel.instantiates.rawValue, "instantiates")
        XCTAssertEqual(EdgeRel.hasState.rawValue, "has_state")
        XCTAssertEqual(EdgeRel.produces.rawValue, "produces")
        XCTAssertEqual(EdgeRel.appearsIn.rawValue, "appears_in")
        XCTAssertEqual(EdgeRel.translatesTo.rawValue, "translates_to")
        XCTAssertEqual(EdgeRel.aggregatesTo.rawValue, "aggregates_to")
        XCTAssertEqual(EdgeRel.contains.rawValue, "contains")
        XCTAssertEqual(EdgeRel.highlightedIn.rawValue, "highlighted_in")
        XCTAssertEqual(EdgeRel.mapsTo.rawValue, "maps_to")
        XCTAssertEqual(EdgeRel.owns.rawValue, "owns")
        XCTAssertEqual(EdgeRel.hasMedia.rawValue, "has_media")
    }

    // MARK: - ComponentID

    func testComponentIDRawValues() {
        XCTAssertEqual(ComponentID.text.rawValue, "text")
        XCTAssertEqual(ComponentID.lemmaMeta.rawValue, "lemma_meta")
        XCTAssertEqual(ComponentID.deckMeta.rawValue, "deck_meta")
        XCTAssertEqual(ComponentID.scheduleState.rawValue, "schedule_state")
        XCTAssertEqual(ComponentID.reviewEvent.rawValue, "review_event")
        XCTAssertEqual(ComponentID.mediaRefs.rawValue, "media_refs")
        XCTAssertEqual(ComponentID.generationMeta.rawValue, "generation_meta")
        XCTAssertEqual(ComponentID.edgeSpan.rawValue, "edge_span")
        XCTAssertEqual(ComponentID.edgeWeighted.rawValue, "edge_weighted")
        XCTAssertEqual(ComponentID.edgePosition.rawValue, "edge_position")
        XCTAssertEqual(ComponentID.tagSet.rawValue, "tag_set")
        XCTAssertEqual(ComponentID.order.rawValue, "order")
        XCTAssertEqual(ComponentID.customData.rawValue, "custom_data")
        XCTAssertEqual(ComponentID.importFailure.rawValue, "import_failure")
        XCTAssertEqual(ComponentID.analyticsCache.rawValue, "analytics_cache")
    }

    // MARK: - Rating

    func testRatingRawValues() {
        XCTAssertEqual(Rating.again.rawValue, 1)
        XCTAssertEqual(Rating.hard.rawValue, 2)
        XCTAssertEqual(Rating.good.rawValue, 3)
        XCTAssertEqual(Rating.easy.rawValue, 4)
    }

    // MARK: - SchedulerID

    func testSchedulerIDRawValues() {
        XCTAssertEqual(SchedulerID.fsrsV4.rawValue, "fsrs-v4")
        XCTAssertEqual(SchedulerID.sm2.rawValue, "sm-2")
    }

    // MARK: - DeckSourceKind

    func testDeckSourceKindRoundTrip() {
        XCTAssertEqual(DeckSourceKind(rawValue: "anki"), .anki)
        XCTAssertEqual(DeckSourceKind(rawValue: "csv"), .csv)
        XCTAssertEqual(DeckSourceKind(rawValue: "manual"), .manual)
    }

    // MARK: - GenerationMode

    func testGenerationModeRoundTrip() {
        XCTAssertEqual(GenerationMode(rawValue: "generate"), .generate)
        XCTAssertEqual(GenerationMode(rawValue: "rewrite"), .rewrite)
    }

    // MARK: - QualityTier

    func testQualityTierRoundTrip() {
        XCTAssertEqual(QualityTier(rawValue: "fast"), .fast)
        XCTAssertEqual(QualityTier(rawValue: "local"), .local)
        XCTAssertEqual(QualityTier(rawValue: "remote"), .remote)
    }

    // MARK: - GenerationConstraints

    func testGenerationConstraintsDefaults() {
        let c = GenerationConstraints()
        XCTAssertEqual(c.maxWords, 300)
        XCTAssertEqual(c.language, "auto")
        XCTAssertTrue(c.preserveTone)
        XCTAssertEqual(c.synonymDistance, 0.4)
    }

    // MARK: - EntityID

    func testEntityIDIsString() {
        let id: EntityID = "test-123"
        XCTAssertEqual(id, "test-123")
    }
}
