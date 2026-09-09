import XCTest
import GRDB
@testable import WordRecitingApp

/// 系统词典：HTML 清洗（parseEntry 纯函数）+ ViewModel（注入查询闭包 + 标记会不会落库）。
final class SystemDictionaryTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    // MARK: - parseEntry 清洗

    func testParseEntryExtractsPhoneticAndPartOfSpeech() {
        let html = """
        <span class="headword">abandon</span> <span class="syllable">a·ban·don</span> \
        <span class="phonetic">| əˈbandən |</span> <span class="pos">verb</span> \
        <span class="definition">1 cease to support or look after (someone); desert: \
        <span class="example">her natural mother had abandoned her at an early age.</span></span>
        """
        let entry = SystemDictionaryService.parseEntry(word: "abandon", html: html)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.word, "abandon")
        XCTAssertEqual(entry?.phonetic, "əˈbandən")
        XCTAssertEqual(entry?.partOfSpeech, "verb")
        XCTAssertTrue(entry?.definition.contains("cease to support") == true)
        XCTAssertTrue(entry?.definition.contains("her natural mother had abandoned") == true,
                      "嵌套标签应被剥除")
        XCTAssertFalse(entry?.definition.contains("<") == true, "HTML 标签应完全剥除")
    }

    func testParseEntryNoPhoneticFallsBackToNil() {
        let html = "<span class=\"headword\">cat</span> <span class=\"pos\">noun</span> a small animal."
        let entry = SystemDictionaryService.parseEntry(word: "cat", html: html)
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.phonetic, "不含 IPA 字符的 | 段不应被当作音标")
        XCTAssertEqual(entry?.partOfSpeech, "noun")
    }

    func testParseEntryDecodesEntitiesAndCollapsesWhitespace() {
        let html = "<span>take</span>&nbsp;&amp;&nbsp;<span>hold</span>   together."
        let entry = SystemDictionaryService.parseEntry(word: "take", html: html)
        XCTAssertEqual(entry?.definition, "take & hold together.")
    }

    func testParseEntryEmptyHTMLReturnsNil() {
        XCTAssertNil(SystemDictionaryService.parseEntry(word: "x", html: "  "))
        XCTAssertNil(SystemDictionaryService.parseEntry(word: "x", html: ""))
    }

    // MARK: - ViewModel（注入查询闭包，不依赖真实系统词典）

    @MainActor
    private func makeVM(entries: [String: DictionaryEntry])
        -> SystemDictionaryViewModel {
        SystemDictionaryViewModel(world: world, lookupOverride: { word in
            entries[word.lowercased()]
        })
    }

    @MainActor
    func testSearchFoundSetsPhaseAndPendingState() async {
        let entry = DictionaryEntry(word: "abandon", phonetic: "əˈbandən",
                                    partOfSpeech: "verb",
                                    definition: "to stop supporting someone")
        let vm = makeVM(entries: ["abandon": entry])
        await vm.search("abandon")
        guard case .found(let e) = vm.phase else {
            return XCTFail("应命中 found，实际 \(vm.phase)")
        }
        XCTAssertEqual(e.word, "abandon")
        XCTAssertEqual(vm.wordState, .pending, "未标记过应为 pending")
        XCTAssertEqual(vm.lastQuery, "abandon")
    }

    @MainActor
    func testSearchNotFound() async {
        let vm = makeVM(entries: [:])
        await vm.search("zzzz")
        guard case .notFound(let word) = vm.phase else {
            return XCTFail("应命中 notFound，实际 \(vm.phase)")
        }
        XCTAssertEqual(word, "zzzz")
    }

    @MainActor
    func testSearchEmptyStaysIdle() async {
        let vm = makeVM(entries: [:])
        await vm.search("   ")
        XCTAssertEqual(vm.phase, .idle)
    }

    @MainActor
    func testToggleMarkPersistsMastery() async throws {
        let entry = DictionaryEntry(word: "abandon", phonetic: nil, partOfSpeech: "verb",
                                    definition: "to stop")
        let vm = makeVM(entries: ["abandon": entry])
        await vm.search("abandon")
        XCTAssertEqual(vm.wordState, .pending)

        // 标记会 → 全局显式掌握度 = 2（词元自动创建，不建卡）。
        // 概率主口径下，单次 markKnown 事件的后验（≈0.83）尚未到 knownThreshold，故显示「学习中」。
        vm.toggleMark("abandon")
        let lemmaID = try XCTUnwrap(try world.graph.findLemmaId(byTextA: "abandon"))
        XCTAssertEqual(try world.graph.lemmaMastery(lemmaId: lemmaID), 2.0)
        guard case .learning = vm.wordState else {
            return XCTFail("概率主口径：单次标记会应为 learning，实际 \(vm.wordState)")
        }

        // 再点（方向由显式标记决定）→ 标记不会 → 掌握度 = 1
        vm.toggleMark("abandon")
        XCTAssertEqual(try world.graph.lemmaMastery(lemmaId: lemmaID), 1.0)
    }

    // MARK: - 真实系统词典（本机可用则验证，否则跳过）

    func testRealSystemDictionaryLookup() async throws {
        let service = SystemDictionaryService()
        guard service.isAvailable() else {
            throw XCTSkip("系统词典服务不可用")
        }
        let entry = await service.lookup("abandon")
        if let entry {
            XCTAssertTrue(entry.definition.count > 20, "应返回完整释义")
            XCTAssertTrue(entry.definition.lowercased().contains("abandon"))
        }
        // 查不到的词返回 nil（不崩溃）
        let missing = await service.lookup("zzzzqqqxx")
        XCTAssertNil(missing)
    }

    // MARK: - 概率主口径 + 词画像

    private func seedProfileLemma() throws {
        let now = Date()
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: now)
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 0,
            source: "init", updatedAt: now))
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "test"))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.10, opportunities: 4,
            lastEventAt: now, updatedAt: now, paramsVersion: "bkt-1"))
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .lookup,
            trust: 1.0, detail: nil))
    }

    @MainActor
    func testWordStateIsDrivenByBelief() async throws {
        try seedProfileLemma()
        let vm = SystemDictionaryViewModel(
            world: world,
            lookupOverride: { word in
                DictionaryEntry(word: word, phonetic: nil,
                                partOfSpeech: nil, definition: "d")
            })

        await vm.search("abandon")

        // 用户显式标了「会」，但概率 0.10 → 判定为不会
        XCTAssertEqual(vm.wordState, .unknown)
    }

    @MainActor
    func testProfileLoadsBeliefBandAndEvents() async throws {
        try seedProfileLemma()
        let vm = SystemDictionaryViewModel(
            world: world,
            lookupOverride: { word in
                DictionaryEntry(word: word, phonetic: nil,
                                partOfSpeech: nil, definition: "d")
            })

        await vm.search("abandon")

        XCTAssertEqual(vm.belief ?? 0, 0.10, accuracy: 0.0001)
        XCTAssertEqual(vm.frequencyBand, 2)
        XCTAssertEqual(vm.frequencyRank, 1001)
        XCTAssertEqual(vm.recentEvents.count, 1)
        XCTAssertEqual(vm.recentEvents.first?.kindLabel, "查词")
        XCTAssertEqual(vm.recentEvents.first?.regionLabel, "词典")
    }

    @MainActor
    func testProfileClearedForUnknownWord() async throws {
        let vm = SystemDictionaryViewModel(
            world: world,
            lookupOverride: { word in
                DictionaryEntry(word: word, phonetic: nil,
                                partOfSpeech: nil, definition: "d")
            })

        await vm.search("zzzzz")

        XCTAssertNil(vm.belief)
        XCTAssertNil(vm.frequencyBand)
        XCTAssertTrue(vm.recentEvents.isEmpty)
    }
}
