import XCTest
import GRDB
@testable import WordRecitingApp

@MainActor
final class StudyPolicyTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func makeCard(lemmaId: String, cardId: String, band: Int?) throws {
        let now = Date()
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: now)
        try world.registry.insertNode(id: cardId, kind: .card, createdAt: now)
        try world.registry.insertEdge(id: "edge-\(cardId)", srcId: cardId, dstId: lemmaId,
                                      rel: .instantiates, createdAt: now)
        if let band {
            try world.registry.upsertComponent(LemmaFrequencyComponent(
                entityId: lemmaId, band: band, freqRank: band * 1000, source: "test"))
        }
    }

    private func state(_ cardId: String) throws -> ScheduleStateComponent? {
        try world.registry.fetchComponents(for: cardId, table: "comp_schedule_state")
    }

    func testDefaultPolicyIsSM2() throws {
        try makeCard(lemmaId: "L1", cardId: "C1", band: nil)

        try world.run(StudySystem(), context: StudySystem.StudyOp(
            cardId: "C1", rating: .good, reviewedAt: Date()))

        XCTAssertEqual(try state("C1")?.intervalDays ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(try state("C1")?.schedulerId, "sm-2")
    }

    func testFrequencyPolicyExtendsHighFrequencyWord() throws {
        try makeCard(lemmaId: "L1", cardId: "C1", band: 1)

        try world.run(StudySystem(), context: StudySystem.StudyOp(
            cardId: "C1", rating: .good, reviewedAt: Date(), policyID: .sm2Frequency))

        XCTAssertEqual(try state("C1")?.intervalDays ?? 0, 3 * 1.3, accuracy: 0.0001)
        XCTAssertEqual(try state("C1")?.schedulerId, "sm-2-frequency")
    }

    func testFrequencyPolicyShortsLowFrequencyWord() throws {
        try makeCard(lemmaId: "L1", cardId: "C1", band: 25)

        try world.run(StudySystem(), context: StudySystem.StudyOp(
            cardId: "C1", rating: .good, reviewedAt: Date(), policyID: .sm2Frequency))

        XCTAssertEqual(try state("C1")?.intervalDays ?? 0, 3 * 0.8, accuracy: 0.0001)
    }

    func testWritesReviewEvent() throws {
        try makeCard(lemmaId: "L1", cardId: "C1", band: nil)

        try world.run(StudySystem(), context: StudySystem.StudyOp(
            cardId: "C1", rating: .good, reviewedAt: Date()))

        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_review_event")
        }
        XCTAssertEqual(count, 1)
    }
}
