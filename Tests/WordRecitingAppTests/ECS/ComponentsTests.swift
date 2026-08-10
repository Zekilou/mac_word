import XCTest
import GRDB
@testable import WordRecitingApp

final class ComponentsTests: XCTestCase {

    private var appDB: AppDatabase!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
    }

    private func insertNode(_ id: String, _ kind: String) throws {
        try appDB.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)",
                           arguments: [id, kind, Date()])
        }
    }

    // TextComponent
    func testTextComponentRoundTrip() throws {
        try insertNode("n1", "card")
        let comp = TextComponent(entityId: "n1", textA: "hello", textB: "你好", language: "en")
        try appDB.dbWriter.write { try comp.insert($0) }
        let fetched = try appDB.dbWriter.read { try TextComponent.fetchOne($0, key: "n1") }
        XCTAssertEqual(fetched?.textA, "hello")
        XCTAssertEqual(fetched?.textB, "你好")
        XCTAssertEqual(fetched?.language, "en")
    }

    // ScheduleStateComponent (Date, Double, Int)
    func testScheduleStateRoundTrip() throws {
        try insertNode("n2", "card")
        let now = Date()
        let comp = ScheduleStateComponent(
            entityId: "n2", stability: 5.5, difficulty: 0.3,
            dueAt: now, intervalDays: 2.0, reps: 10, lapses: 1,
            lastRating: 3, lastReviewedAt: now,
            schedulerId: "fsrs-v4", queue: "review", customDataJson: nil
        )
        try appDB.dbWriter.write { try comp.insert($0) }
        let fetched = try appDB.dbWriter.read { try ScheduleStateComponent.fetchOne($0, key: "n2") }
        XCTAssertEqual(fetched?.stability, 5.5)
        XCTAssertEqual(fetched?.difficulty, 0.3)
        XCTAssertEqual(fetched?.reps, 10)
        XCTAssertEqual(fetched?.lapses, 1)
        XCTAssertEqual(fetched?.schedulerId, "fsrs-v4")
        XCTAssertEqual(fetched?.queue, "review")
    }

    // EdgeSpanComponent (Bool, Int)
    func testEdgeSpanRoundTrip() throws {
        try insertNode("n3", "edge")
        let comp = EdgeSpanComponent(entityId: "n3", surfaceForm: "abandon", start: 10, end: 17, isTarget: true)
        try appDB.dbWriter.write { try comp.insert($0) }
        let fetched = try appDB.dbWriter.read { try EdgeSpanComponent.fetchOne($0, key: "n3") }
        XCTAssertEqual(fetched?.surfaceForm, "abandon")
        XCTAssertEqual(fetched?.start, 10)
        XCTAssertEqual(fetched?.end, 17)
        XCTAssertEqual(fetched?.isTarget, true)
    }

    // ReviewEventComponent (Date, Int, Double)
    func testReviewEventRoundTrip() throws {
        try insertNode("n4", "event")
        let now = Date()
        let comp = ReviewEventComponent(
            entityId: "n4", targetCardId: "card-1", ratedAt: now,
            rating: 1, respondedMs: 5000, elapsedDays: 2.0,
            scheduledInterval: 1.5, deltaStability: -0.5,
            deltaDifficulty: 0.1, lastIvl: 3.0, factor: 2.5
        )
        try appDB.dbWriter.write { try comp.insert($0) }
        let fetched = try appDB.dbWriter.read { try ReviewEventComponent.fetchOne($0, key: "n4") }
        XCTAssertEqual(fetched?.targetCardId, "card-1")
        XCTAssertEqual(fetched?.rating, 1)
        XCTAssertEqual(fetched?.respondedMs, 5000)
        XCTAssertEqual(fetched?.deltaStability, -0.5)
        XCTAssertEqual(fetched?.factor, 2.5)
    }

    // EdgeWeightedComponent (Double, String)
    func testEdgeWeightedRoundTrip() throws {
        try insertNode("n5", "edge")
        let comp = EdgeWeightedComponent(entityId: "n5", weightDouble: 0.9, sourceType: "user")
        try appDB.dbWriter.write { try comp.insert($0) }
        let fetched = try appDB.dbWriter.read { try EdgeWeightedComponent.fetchOne($0, key: "n5") }
        XCTAssertEqual(fetched?.weightDouble, 0.9)
        XCTAssertEqual(fetched?.sourceType, "user")
    }

    // DeckMetaComponent (String, Date)
    func testDeckMetaRoundTrip() throws {
        try insertNode("n6", "deck")
        let now = Date()
        let comp = DeckMetaComponent(entityId: "n6", name: "GRE 3000", sourceKind: "csv", sourcePath: "/tmp/gre.csv", importedAt: now)
        try appDB.dbWriter.write { try comp.insert($0) }
        let fetched = try appDB.dbWriter.read { try DeckMetaComponent.fetchOne($0, key: "n6") }
        XCTAssertEqual(fetched?.name, "GRE 3000")
        XCTAssertEqual(fetched?.sourceKind, "csv")
        XCTAssertEqual(fetched?.sourcePath, "/tmp/gre.csv")
    }

    // GenerationMetaComponent
    func testGenerationMetaRoundTrip() throws {
        try insertNode("n7", "article")
        let comp = GenerationMetaComponent(entityId: "n7", mode: "rewrite", topic: "science", sourceText: "orig", generatorId: "rule-based", qualityTier: "fast", promptHash: "abc123")
        try appDB.dbWriter.write { try comp.insert($0) }
        let fetched = try appDB.dbWriter.read { try GenerationMetaComponent.fetchOne($0, key: "n7") }
        XCTAssertEqual(fetched?.mode, "rewrite")
        XCTAssertEqual(fetched?.generatorId, "rule-based")
        XCTAssertEqual(fetched?.qualityTier, "fast")
        XCTAssertEqual(fetched?.promptHash, "abc123")
    }

    // AnalyticsCacheComponent
    func testAnalyticsCacheRoundTrip() throws {
        try insertNode("n8", "event")
        let comp = AnalyticsCacheComponent(entityId: "n8", moduleId: "heatmap", scopeHash: "hash123", computedAt: Date(), payloadJson: "{\"data\":[]}")
        try appDB.dbWriter.write { try comp.insert($0) }
        let fetched = try appDB.dbWriter.read { try AnalyticsCacheComponent.fetchOne($0, key: "n8") }
        XCTAssertEqual(fetched?.moduleId, "heatmap")
        XCTAssertEqual(fetched?.scopeHash, "hash123")
        XCTAssertEqual(fetched?.payloadJson, "{\"data\":[]}")
    }

    // Update via save
    func testComponentSaveUpdate() throws {
        try insertNode("n9", "card")
        var comp = TextComponent(entityId: "n9", textA: "old", textB: nil, language: nil)
        try appDB.dbWriter.write { try comp.insert($0) }
        comp.textA = "new"
        try appDB.dbWriter.write { try comp.save($0) }
        let fetched = try appDB.dbWriter.read { try TextComponent.fetchOne($0, key: "n9") }
        XCTAssertEqual(fetched?.textA, "new")
    }
}
