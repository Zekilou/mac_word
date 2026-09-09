import XCTest
import GRDB
@testable import WordRecitingApp

/// 造文文章全词状态测试：词块 token 化 / 目标词 span 匹配 / 状态判定 / 点击切换落库。
final class GenerateArticleWordsTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        suiteName = "ArticleWords-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeVM() -> GenerateViewModel {
        GenerateViewModel(world: world, settings: AppSettings(defaults: defaults))
    }

    private func targetSpan(_ start: Int, _ end: Int, lemmaId: String) -> SpanInfo {
        SpanInfo(start: start, end: end, isTarget: true, lemmaId: lemmaId,
                 surfaceForm: "", replacedFrom: nil)
    }

    // MARK: - 分词 + 目标词匹配

    /// 词块 token 化：词 + 区间；标点/空白被跳过（仅返回词）。
    func testMakeArticleWordsSegmentsAndMatchesTargets() {
        let body = "The battle begins! We fight."
        // "battle" 在 4..<10，标记为目标词
        let words = GenerateViewModel.makeArticleWords(
            body: body, spans: [targetSpan(4, 10, lemmaId: "lemma-battle")])

        let surfaces = words.map(\.surface)
        XCTAssertEqual(surfaces, ["The", "battle", "begins", "We", "fight"])
        XCTAssertEqual(words[1].isTarget, true)
        XCTAssertEqual(words[1].lemmaId, "lemma-battle")
        XCTAssertEqual(words[1].start, 4)
        XCTAssertEqual(words[1].end, 10)
        XCTAssertEqual(words[0].isTarget, false)
        XCTAssertEqual(words[0].lemma, "the", "lemma 归一化小写")
    }

    /// 屈折变体归一化：Battles → battle。
    func testMakeArticleWordsNormalizesInflection() {
        let body = "Battles are fought"
        let words = GenerateViewModel.makeArticleWords(body: body, spans: [])
        XCTAssertEqual(words[0].lemma, "battle")
        XCTAssertEqual(words[0].surface, "Battles")
    }

    // MARK: - 渲染 token（词 + 标点）

    /// 渲染 token：词块与标点交替，空白跳过。
    func testReadTokensInterleavesPunctuation() {
        let body = "The battle, yes!"
        let words = GenerateViewModel.makeArticleWords(body: body, spans: [])
        let tokens = GenerateView.readTokens(of: body, words: words)

        let rendered = tokens.map { item -> String in
            switch item.tok {
            case .word(let w): return w.surface
            case .punct(let p): return p
            }
        }
        XCTAssertEqual(rendered, ["The", "battle", ",", "yes", "!"])
    }

    // MARK: - 状态判定

    /// 无记录词 → pending；写全局记录后 → 对应状态。
    @MainActor func testArticleMarkStateReflectsGlobal() throws {
        let vm = makeVM()
        let body = "battle cat"
        let words = GenerateViewModel.makeArticleWords(body: body, spans: [])
        XCTAssertEqual(vm.articleMarkState(for: words[0]), .pending, "未记录默认灰")

        // 标记 battle 为会（2.0）
        try world.run(UserKnownSystem(), context: .batch(words: [("battle", true)], source: "test"))
        vm.loadWordMastery()
        XCTAssertEqual(vm.articleMarkState(for: words[0]), .known)
    }

    /// 会话覆盖优先于全局。
    @MainActor func testArticleMarkStateSessionOverrides() throws {
        let vm = makeVM()
        let body = "battle cat"
        let words = GenerateViewModel.makeArticleWords(body: body, spans: [])
        try world.run(UserKnownSystem(), context: .batch(words: [("battle", true)], source: "test"))
        vm.loadWordMastery()

        vm.sessionWordStates["battle"] = false
        XCTAssertEqual(vm.articleMarkState(for: words[0]), .unknown, "会话标红覆盖全局绿")
    }

    // MARK: - 点击切换 + 落库

    /// 三态循环：灰 → 红（手动）→ 回灰（跟随全局）；点击立即落库。
    @MainActor func testToggleArticleWordCycleAndPersists() throws {
        let vm = makeVM()
        let body = "battle cat"
        let words = GenerateViewModel.makeArticleWords(body: body, spans: [])
        let token = words[0]

        vm.toggleArticleWord(token)   // 灰 → 红
        XCTAssertEqual(vm.articleMarkState(for: token), .unknown)
        var mastery = try world.graph.knownLemmaMastery()
        XCTAssertEqual(mastery["lemma:battle"], 1.0, "立即落库为不会")

        vm.toggleArticleWord(token)   // 手动红 → 回灰/跟全局（清除会话覆盖）
        XCTAssertNil(vm.sessionWordStates["battle"], "回灰时清除会话覆盖")
        XCTAssertEqual(vm.articleMarkState(for: token), .unknown, "清除后跟随全局记录（仍是不 会→不会）")
    }

    /// 记录红 → 绿：已有"不会"记录的词点击变"会"。
    @MainActor func testToggleArticleWordRecordUnknownToKnown() throws {
        let vm = makeVM()
        try world.run(UserKnownSystem(), context: .batch(words: [("battle", false)], source: "test"))
        vm.loadWordMastery()
        let body = "battle cat"
        let words = GenerateViewModel.makeArticleWords(body: body, spans: [])
        let token = words[0]

        XCTAssertEqual(vm.articleMarkState(for: token), .unknown, "记录红")
        vm.toggleArticleWord(token)   // 记录红 → 绿
        XCTAssertEqual(vm.articleMarkState(for: token), .known)
        let mastery = try world.graph.knownLemmaMastery()
        XCTAssertEqual(mastery["lemma:battle"], 2.0, "落库为会")
    }

    /// 流式 → 完成 转换：流式中同 body 只分词不上色；生成完成后同 body 必须重新加载掌握度（防全词灰）。
    /// @ai: 回归用例——守卫键曾只含 body，流式最后 body 占住 loadedBodyKey，完成后短路不加载 → 全灰。
    @MainActor func testArticleWordsReloadMasteryAfterGenerationFinishes() throws {
        try world.run(UserKnownSystem(), context: .batch(words: [("battle", true)], source: "test"))
        let vm = makeVM()
        let body = "battle cat"
        let spans: [SpanInfo] = []

        // 模拟流式中：isGenerating=true → 只分词不上色
        vm.isGenerating = true
        vm.ensureArticleWords(body: body, spans: spans)
        XCTAssertEqual(vm.articleMarkState(for: vm.articleWords[0]), .pending,
                       "流式中不上色（防卡，灰）")

        // 生成完成：isGenerating=false，同 body → 必须重新加载掌握度上色
        vm.isGenerating = false
        vm.ensureArticleWords(body: body, spans: spans)
        XCTAssertEqual(vm.articleMarkState(for: vm.articleWords[0]), .known,
                       "完成后同 body 重新加载，battle（已会）应绿")

        // 完成态重绘：key 不变 → 零副作用返回（不重复加载/不循环）
        vm.ensureArticleWords(body: body, spans: spans)
        XCTAssertEqual(vm.articleMarkState(for: vm.articleWords[0]), .known,
                       "完成后重复调用保持状态")
    }

    /// 造文页主动标记 → 写高可信词事件（region = generate）。
    @MainActor func testSetArticleWordExtremeRecordsTrustedEvent() throws {
        let vm = makeVM()
        let body = "battle cat"
        let words = GenerateViewModel.makeArticleWords(body: body, spans: [])
        let token = words[0]

        vm.ensureArticleWords(body: body, spans: [])
        vm.setArticleWordExtreme(token, known: false)

        let count = try appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM comp_word_event WHERE trust = 1 AND event_kind = 'mark_unknown'
                """)
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - 概率主口径

    @MainActor func testArticleMarkStateIsDrivenByBelief() throws {
        let vm = makeVM()
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 0,
            source: "reading", updatedAt: Date()))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.1, opportunities: 3,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))

        vm.loadWordMastery()
        // 非目标词才走全局状态判定（目标词固定 .pending）
        let token = ArticleWordToken(
            id: 0, surface: "abandon", lemma: "abandon",
            start: 0, end: 7, isTarget: false, lemmaId: "L1")

        XCTAssertEqual(vm.articleMarkState(for: token), .unknown)
    }
}
