import XCTest
import GRDB
@testable import WordRecitingApp

final class GraphQueriesTests: XCTestCase {

    private var appDB: AppDatabase!
    private var registry: EntityRegistry!
    private var graph: GraphQueries!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        registry = EntityRegistry(database: appDB)
        graph = GraphQueries(database: appDB)
    }

    // 测试辅助：插节点
    private func node(_ id: String, _ kind: NodeKind) throws {
        try registry.insertNode(id: id, kind: kind, createdAt: epoch)
    }

    // 测试辅助：插边
    private func edge(_ id: String, _ src: String, _ dst: String, _ rel: EdgeRel) throws {
        try registry.insertEdge(id: id, srcId: src, dstId: dst, rel: rel, createdAt: epoch)
    }

    // MARK: - neighbors

    func testNeighborsOneHop() throws {
        try node("deck", .deck)
        try node("card-a", .card)
        try node("card-b", .card)
        try edge("e1", "deck", "card-a", .has)
        try edge("e2", "deck", "card-b", .has)

        let ns = try graph.neighbors(of: "deck", rel: nil)
        XCTAssertEqual(ns.count, 2)
        let pairs = Set(ns.map { "\($0.srcId)>\($0.dstId)" })
        XCTAssertEqual(pairs, Set(["deck>card-a", "deck>card-b"]))
    }

    func testNeighborsFilteredByRel() throws {
        try node("deck", .deck)
        try node("card", .card)
        try node("lemma", .lemma)
        try edge("e1", "deck", "card", .has)
        try edge("e2", "card", "lemma", .instantiates)

        // 只取 has 边
        let hasOnly = try graph.neighbors(of: "card", rel: .has)
        XCTAssertEqual(hasOnly.count, 1)
        XCTAssertEqual(hasOnly.first?.srcId, "deck")
        XCTAssertEqual(hasOnly.first?.dstId, "card")
        XCTAssertEqual(hasOnly.first?.relType, "has")

        // 只取 instantiates 边
        let inst = try graph.neighbors(of: "card", rel: .instantiates)
        XCTAssertEqual(inst.count, 1)
        XCTAssertEqual(inst.first?.dstId, "lemma")
    }

    func testNeighborsBothDirections() throws {
        // card 作为 dst 也应被识别为 deck 的邻居，反之 card 视角也能看到 deck
        try node("deck", .deck)
        try node("card", .card)
        try edge("e1", "deck", "card", .has)

        let fromCard = try graph.neighbors(of: "card", rel: nil)
        XCTAssertEqual(fromCard.count, 1)
        XCTAssertEqual(fromCard.first?.srcId, "deck")
    }

    // MARK: - contextSubgraph

    func testContextSubgraphTwoHops() throws {
        // Lemma →(appears_in)→ Sentence →(aggregates_to)→ Article
        try node("lemma", .lemma)
        try node("sent", .sentence)
        try node("art", .article)
        try edge("e1", "lemma", "sent", .appearsIn)
        try edge("e2", "sent", "art", .aggregatesTo)

        let sub = try graph.contextSubgraph(for: "lemma", depth: 2)
        XCTAssertEqual(sub.nodeIds, Set(["lemma", "sent", "art"]))
        XCTAssertEqual(sub.edges.count, 2)
        let edgeKeys = Set(sub.edges.map { "\($0.srcId)>\($0.dstId):\($0.relType)" })
        XCTAssertEqual(edgeKeys, Set(["lemma>sent:appears_in", "sent>art:aggregates_to"]))
    }

    func testContextSubgraphDepthOne() throws {
        try node("lemma", .lemma)
        try node("sent", .sentence)
        try node("art", .article)
        try edge("e1", "lemma", "sent", .appearsIn)
        try edge("e2", "sent", "art", .aggregatesTo)

        let sub = try graph.contextSubgraph(for: "lemma", depth: 1)
        // 只到 sentence
        XCTAssertEqual(sub.nodeIds, Set(["lemma", "sent"]))
        XCTAssertEqual(sub.edges.count, 1)
    }

    func testContextSubgraphLargeDepthStillWorks() throws {
        // 超过 5 跳应 print warning 但不崩溃，仍返回可达节点
        try node("n0", .lemma)
        try node("n1", .sentence)
        try node("n2", .article)
        try edge("e1", "n0", "n1", .appearsIn)
        try edge("e2", "n1", "n2", .aggregatesTo)

        let sub = try graph.contextSubgraph(for: "n0", depth: 6)
        XCTAssertEqual(sub.nodeIds, Set(["n0", "n1", "n2"]))
    }

    // MARK: - weakLemmas

    func testWeakLemmasFiltersByAgainRatio() throws {
        // 5 张卡 × 20 次复习；3 张 again_ratio≥30%
        try node("deck", .deck)
        let againCounts = [10, 8, 7, 2, 0]  // 0.5, 0.4, 0.35, 0.1, 0.0
        for i in 0..<5 {
            let cardId = "card-\(i)"
            let lemmaId = "lemma-\(i)"
            try node(cardId, .card)
            try node(lemmaId, .lemma)
            try edge("has-\(i)", "deck", cardId, .has)
            try edge("inst-\(i)", cardId, lemmaId, .instantiates)
            // 20 次复习
            for r in 0..<20 {
                let eventId = "evt-\(i)-\(r)"
                try node(eventId, .event)
                try edge("prod-\(i)-\(r)", cardId, eventId, .produces)
                let rating = r < againCounts[i] ? Rating.again.rawValue : Rating.good.rawValue
                try registry.upsertComponent(ReviewEventComponent(
                    entityId: eventId, targetCardId: cardId, ratedAt: epoch,
                    rating: rating, respondedMs: nil, elapsedDays: nil,
                    scheduledInterval: nil, deltaStability: nil,
                    deltaDifficulty: nil, lastIvl: nil, factor: nil))
            }
        }

        let weak = try graph.weakLemmas(in: "deck", thresholdAgainRatio: 0.3)
        XCTAssertEqual(Set(weak), Set(["lemma-0", "lemma-1", "lemma-2"]))
    }

    func testWeakLemmasHighThresholdReturnsNone() throws {
        try node("deck", .deck)
        try node("card", .card)
        try node("lemma", .lemma)
        try edge("has", "deck", "card", .has)
        try edge("inst", "card", "lemma", .instantiates)
        // 5 again / 20 = 0.25
        for r in 0..<20 {
            let eventId = "evt-\(r)"
            try node(eventId, .event)
            try edge("prod-\(r)", "card", eventId, .produces)
            try registry.upsertComponent(ReviewEventComponent(
                entityId: eventId, targetCardId: "card", ratedAt: epoch,
                rating: r < 5 ? Rating.again.rawValue : Rating.good.rawValue,
                respondedMs: nil, elapsedDays: nil, scheduledInterval: nil,
                deltaStability: nil, deltaDifficulty: nil, lastIvl: nil, factor: nil))
        }
        let weak = try graph.weakLemmas(in: "deck", thresholdAgainRatio: 0.9)
        XCTAssertTrue(weak.isEmpty)
    }

    // MARK: - synonymCooccurrence

    func testSynonymCooccurrence() throws {
        // 2 篇 article；article1 含 lemmaA/B/C，article2 含 lemmaA/B
        try node("art-1", .article)
        try node("art-2", .article)
        try node("lemmaA", .lemma)
        try node("lemmaB", .lemma)
        try node("lemmaC", .lemma)
        // article →(contains)→ lemma
        try edge("c1a", "art-1", "lemmaA", .contains)
        try edge("c1b", "art-1", "lemmaB", .contains)
        try edge("c1c", "art-1", "lemmaC", .contains)
        try edge("c2a", "art-2", "lemmaA", .contains)
        try edge("c2b", "art-2", "lemmaB", .contains)

        let cooc = try graph.synonymCooccurrence(for: ["lemmaA"], inArticleCount: 2)
        // lemmaA 与 lemmaB 共现 2 次，与 lemmaC 共现 1 次
        let asMap = Dictionary(cooc.map { ($0.0 + ">" + $0.1, $0.2) }, uniquingKeysWith: { _, b in b })
        XCTAssertEqual(asMap["lemmaA>lemmaB"], 2)
        XCTAssertEqual(asMap["lemmaA>lemmaC"], 1)
    }

    func testSynonymCooccurrenceLimitedByArticleCount() throws {
        // 3 篇 article 都含 lA/lB；inArticleCount=1 只取最近 1 篇 → 共现 1
        try node("lA", .lemma)
        try node("lB", .lemma)
        for i in 0..<3 {
            let aid = "art-\(i)"
            // 后建的 created_at 更晚，保证 ORDER BY created_at DESC 取到 art-2
            try appDB.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO nodes (id, kind, created_at) VALUES (?, ?, ?)",
                               arguments: [aid, NodeKind.article.rawValue,
                                           Date(timeIntervalSince1970: 1_700_000_000 + Double(i))])
            }
            try edge("ca-\(i)", aid, "lA", .contains)
            try edge("cb-\(i)", aid, "lB", .contains)
        }
        let cooc = try graph.synonymCooccurrence(for: ["lA"], inArticleCount: 1)
        let total = cooc.reduce(0) { $0 + $1.2 }
        XCTAssertEqual(total, 1, "只取最近 1 篇 article，应只有 1 次共现")
    }
}
