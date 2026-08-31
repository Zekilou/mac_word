import XCTest
import GRDB
@testable import WordRecitingApp

final class GraphQueriesSynonymsTests: XCTestCase {

    private var appDB: AppDatabase!
    private var registry: EntityRegistry!
    private var graph: GraphQueries!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        registry = EntityRegistry(database: appDB)
        graph = GraphQueries(database: appDB)
    }

    private func node(_ id: String, _ kind: NodeKind) throws {
        try registry.insertNode(id: id, kind: kind, createdAt: epoch)
    }

    private func text(_ id: String, _ a: String, _ b: String? = nil) throws {
        try registry.upsertComponent(TextComponent(
            entityId: id, textA: a, textB: b, language: nil))
    }

    private func setupLemmas() throws {
        // 多个不同前缀的 lemma，用于前缀搜索测试
        try node("L1", .lemma); try text("L1", "abandon", "v. 放弃")
        try node("L2", .lemma); try text("L2", "abase", "v. 贬低")
        try node("L3", .lemma); try text("L3", "abate", "v. 减轻")
        try node("L4", .lemma); try text("L4", "forsake", "v. 抛弃")
        try node("L5", .lemma); try text("L5", "forswear", "v. 发誓放弃")
        try node("L6", .lemma); try text("L6", "benefit", "n. 利益")
    }

    private func setupMapsToEdge(
        _ edgeId: String, src: String, dst: String,
        weight: Double = 1.0, sourceType: String = "user",
        createdAt: Date? = nil
    ) throws {
        let ts = createdAt ?? epoch
        try registry.insertEdge(
            id: edgeId, srcId: src, dstId: dst, rel: .mapsTo, createdAt: ts)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: edgeId, weightDouble: weight, sourceType: sourceType))
    }

    // MARK: - searchLemmas(prefix:)

    func testSearchLemmasPrefixCaseInsensitive() throws {
        try setupLemmas()
        // aba 前缀应命中 abandon / abase / abate（3 个）
        let aba = try graph.searchLemmas(prefix: "aba", limit: 50)
        let abaTexts = Set(aba.map(\.text))
        XCTAssertEqual(abaTexts, Set(["abandon", "abase", "abate"]))
        // 全大写前缀也能命中
        let ABA = try graph.searchLemmas(prefix: "ABA", limit: 50)
        XCTAssertEqual(ABA.count, 3)
    }

    func testSearchLemmasPrefixFors() throws {
        try setupLemmas()
        let fors = try graph.searchLemmas(prefix: "fors", limit: 50)
        let forsTexts = Set(fors.map(\.text))
        XCTAssertEqual(forsTexts, Set(["forsake", "forswear"]))
    }

    func testSearchLemmasEmptyPrefixReturnsEmpty() throws {
        try setupLemmas()
        let empty = try graph.searchLemmas(prefix: "", limit: 50)
        XCTAssertTrue(empty.isEmpty)
    }

    func testSearchLemmasLimitHonored() throws {
        try setupLemmas()
        let limited = try graph.searchLemmas(prefix: "a", limit: 2)
        XCTAssertLessThanOrEqual(limited.count, 2)
    }

    func testSearchLemmasDefinitionIncluded() throws {
        try setupLemmas()
        let results = try graph.searchLemmas(prefix: "abandon", limit: 10)
        let abandon = try XCTUnwrap(results.first)
        XCTAssertEqual(abandon.definition, "v. 放弃")
    }

    // MARK: - listAllSynonymMappings

    func testListAllSynonymMappingsEmpty() throws {
        try setupLemmas()
        XCTAssertTrue(try graph.listAllSynonymMappings().isEmpty)
    }

    func testListAllSynonymMappingsFieldsPopulated() throws {
        try setupLemmas()
        try setupMapsToEdge("e1", src: "L1", dst: "L4",
                            weight: 0.9, sourceType: "user",
                            createdAt: epoch)

        let list = try graph.listAllSynonymMappings()
        XCTAssertEqual(list.count, 1)
        let m = try XCTUnwrap(list.first)
        XCTAssertEqual(m.edgeId, "e1")
        XCTAssertEqual(m.fromLemmaId, "L1")
        XCTAssertEqual(m.toLemmaId, "L4")
        XCTAssertEqual(m.fromText, "abandon")
        XCTAssertEqual(m.toText, "forsake")
        XCTAssertEqual(m.weight, 0.9, accuracy: 0.001)
        XCTAssertEqual(m.sourceType, "user")
        XCTAssertEqual(m.createdAt, epoch)
    }

    func testListAllSynonymMappingsDefaultValues() throws {
        try setupLemmas()
        // 插 edge 但不插 comp_edge_weighted → 应走默认 weight=0.5 sourceType=manual
        try registry.insertEdge(id: "e2", srcId: "L1", dstId: "L4",
                                rel: .mapsTo, createdAt: epoch)

        let list = try graph.listAllSynonymMappings()
        let m = try XCTUnwrap(list.first)
        XCTAssertEqual(m.weight, 0.5, accuracy: 0.001)
        XCTAssertEqual(m.sourceType, "manual")
    }

    func testListAllSynonymMappingsOrderByCreatedAtDesc() throws {
        try setupLemmas()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000)
        let t3 = Date(timeIntervalSince1970: 1_700_002_000)
        try setupMapsToEdge("oldest", src: "L1", dst: "L4", createdAt: t1)
        try setupMapsToEdge("middle", src: "L2", dst: "L5", createdAt: t2)
        try setupMapsToEdge("newest", src: "L3", dst: "L6", createdAt: t3)

        let list = try graph.listAllSynonymMappings()
        let ids = list.map(\.edgeId)
        XCTAssertEqual(ids, ["newest", "middle", "oldest"])
    }

    // MARK: - findMapsToEdgeId（在事务内使用）

    func testFindMapsToEdgeIdForwardMatch() throws {
        try setupLemmas()
        try setupMapsToEdge("e-forward", src: "L1", dst: "L4")

        let id = try appDB.dbWriter.read { db in
            try graph.findMapsToEdgeId(db, a: "L1", b: "L4")
        }
        XCTAssertEqual(id, "e-forward")
    }

    func testFindMapsToEdgeIdReverseMatch() throws {
        try setupLemmas()
        try setupMapsToEdge("e-forward", src: "L1", dst: "L4")

        // 传反向 (L4, L1) 也应命中同一条边
        let id = try appDB.dbWriter.read { db in
            try graph.findMapsToEdgeId(db, a: "L4", b: "L1")
        }
        XCTAssertEqual(id, "e-forward")
    }

    func testFindMapsToEdgeIdNoMatchReturnsNil() throws {
        try setupLemmas()
        let id = try appDB.dbWriter.read { db in
            try graph.findMapsToEdgeId(db, a: "L1", b: "L6")
        }
        XCTAssertNil(id)
    }
}
