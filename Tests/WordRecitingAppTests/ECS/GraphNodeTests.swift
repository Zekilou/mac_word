import XCTest
@testable import WordRecitingApp

final class GraphNodeTests: XCTestCase {

    func testLemmaNodeKind() {
        let node = LemmaNode(id: "l1", createdAt: Date())
        XCTAssertEqual(node.kind, .lemma)
        XCTAssertEqual(node.id, "l1")
    }

    func testCardNodeKind() {
        let node = CardNode(id: "c1", createdAt: Date())
        XCTAssertEqual(node.kind, .card)
    }

    func testDeckNodeKind() {
        let node = DeckNode(id: "d1", createdAt: Date())
        XCTAssertEqual(node.kind, .deck)
    }

    func testSentenceNodeKind() {
        let node = SentenceNode(id: "s1", createdAt: Date())
        XCTAssertEqual(node.kind, .sentence)
    }

    func testArticleNodeKind() {
        let node = ArticleNode(id: "a1", createdAt: Date())
        XCTAssertEqual(node.kind, .article)
    }

    func testEventNodeKind() {
        let node = EventNode(id: "e1", createdAt: Date())
        XCTAssertEqual(node.kind, .event)
    }

    func testEdgeNodeKind() {
        let node = EdgeNode(id: "ed1", createdAt: Date())
        XCTAssertEqual(node.kind, .edge)
    }

    func testCodableRoundTrip() throws {
        let node = CardNode(id: "card-rt", createdAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(CardNode.self, from: data)
        XCTAssertEqual(decoded.id, "card-rt")
        XCTAssertEqual(decoded.createdAt, node.createdAt)
        XCTAssertEqual(decoded.kind, .card)
    }

    func testKindNotEncoded() throws {
        let node = LemmaNode(id: "l2", createdAt: Date())
        let data = try JSONEncoder().encode(node)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"kind\""))
    }

    func testEdgeRecordCodable() throws {
        let edge = EdgeRecord(id: "e1", srcId: "s", dstId: "d", relType: "has", createdAt: Date())
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(EdgeRecord.self, from: data)
        XCTAssertEqual(decoded, edge)
    }
}
