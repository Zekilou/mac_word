import XCTest
import GRDB
@testable import WordRecitingApp

/// RewriteViewModel 逻辑测试：parseTargets 解析 + runRewrite 改写落库 + 历史回看。
/// @ai: 不依赖 SwiftUI，只测 ViewModel 纯逻辑与 World 协作。
/// 类本身非 @MainActor：setUp 只构造 Sendable 依赖；触达 VM 的方法单独标 @MainActor。
final class RewriteViewModelTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry!
    private var graph: GraphQueries!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        registry = world.registry
        graph = world.graph
    }

    /// 造 Lemma A(abandon) → maps_to → B(forsake, weight=0.9, user)
    private func setupLemmaB() throws {
        for (id, text) in [("A", "abandon"), ("B", "forsake")] {
            try registry.insertNode(id: id, kind: .lemma, createdAt: epoch)
            try registry.upsertComponent(TextComponent(
                entityId: id, textA: text, textB: nil, language: nil))
        }
        try registry.insertEdge(id: "e-ab", srcId: "A", dstId: "B", rel: .mapsTo, createdAt: epoch)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: "e-ab", weightDouble: 0.9, sourceType: "user"))
    }

    // MARK: - parseTargets

    func testParseTargetsSplitsByCommaSemicolonNewline() {
        XCTAssertEqual(RewriteViewModel.parseTargets("A,B;C\nD"), ["A", "B", "C", "D"])
    }

    func testParseTargetsTrimsAndDedupesCaseInsensitive() {
        XCTAssertEqual(RewriteViewModel.parseTargets(" A , b \n, a "), ["A", "b"])
    }

    func testParseTargetsIgnoresEmptyAndWhitespace() {
        XCTAssertEqual(RewriteViewModel.parseTargets(",;;\n  ,"), [])
    }

    func testParseTargetsEmptyString() {
        XCTAssertEqual(RewriteViewModel.parseTargets(""), [])
    }

    // MARK: - runRewrite

    @MainActor func testRunRewriteReplacesAndPersists() async throws {
        try setupLemmaB()
        let vm = RewriteViewModel(world: world, generator: RuleBasedGenerator())
        vm.sourceText = "I will abandon this project."
        vm.targetsText = "forsake"
        await vm.runRewrite()

        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isGenerating)
        let article = try XCTUnwrap(vm.resultArticle)
        XCTAssertEqual(article.body, "I will forsake this project.")
        XCTAssertEqual(article.spans.count, 1)
        XCTAssertEqual(article.spans.first?.lemmaId, "B")
        XCTAssertEqual(article.spans.first?.replacedFrom, "abandon")

        // 落库校验：历史列表新增 1 条
        let items = try graph.recentArticles(mode: .rewrite, limit: 20)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.generatorId, "rule-based")
    }

    @MainActor func testRunRewriteUnknownTargetNoReplacement() async throws {
        try setupLemmaB()
        let vm = RewriteViewModel(world: world, generator: RuleBasedGenerator())
        vm.sourceText = "I will abandon this project."
        vm.targetsText = "unknownword"
        await vm.runRewrite()

        XCTAssertNil(vm.errorMessage)
        let article = try XCTUnwrap(vm.resultArticle)
        // 目标词未匹配到 lemma → 不替换，body 原样
        XCTAssertEqual(article.body, "I will abandon this project.")
        XCTAssertEqual(article.spans.count, 0)
    }

    @MainActor func testRunRewriteEmptySourceProducesEmptyBody() async throws {
        try setupLemmaB()
        let vm = RewriteViewModel(world: world, generator: RuleBasedGenerator())
        vm.sourceText = ""
        vm.targetsText = "forsake"
        await vm.runRewrite()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.resultArticle?.body, "")
        XCTAssertEqual(vm.resultArticle?.spans.count, 0)
    }

    // MARK: - 历史

    @MainActor func testLoadHistoryFetchesRecent() async throws {
        try setupLemmaB()
        let vm = RewriteViewModel(world: world, generator: RuleBasedGenerator())
        vm.sourceText = "I will abandon this project."
        vm.targetsText = "forsake"
        await vm.runRewrite()

        vm.loadHistory()
        XCTAssertEqual(vm.history.count, 1)
        XCTAssertEqual(vm.history.first?.generatorId, "rule-based")
        XCTAssertFalse(vm.history.first?.bodyPreview.isEmpty ?? true)
    }

    @MainActor func testSelectHistoryLoadsStoredArticle() async throws {
        try setupLemmaB()
        let vm = RewriteViewModel(world: world, generator: RuleBasedGenerator())
        vm.sourceText = "I will abandon this project."
        vm.targetsText = "forsake"
        await vm.runRewrite()

        vm.loadHistory()
        let id = try XCTUnwrap(vm.history.first?.id)
        vm.selectHistory(id)
        let stored = try XCTUnwrap(vm.selectedArticle)
        XCTAssertEqual(stored.body, "I will forsake this project.")
        XCTAssertEqual(stored.spans.count, 1)
        XCTAssertEqual(stored.spans.first?.lemmaId, "B")
        // 回看 span 的 replacedFrom 不落库 → 恒为 nil
        XCTAssertNil(stored.spans.first?.replacedFrom)
    }
}
