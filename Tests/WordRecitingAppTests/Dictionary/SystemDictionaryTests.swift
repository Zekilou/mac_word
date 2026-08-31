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

        // 标记会 → 全局掌握度 = 2（词元自动创建，不建卡）
        vm.toggleMark("abandon")
        XCTAssertEqual(vm.wordState, .known)
        let lemmaID = try XCTUnwrap(try world.graph.findLemmaId(byTextA: "abandon"))
        XCTAssertEqual(try world.graph.lemmaMastery(lemmaId: lemmaID), 2.0)

        // 再点 → 标记不会 → 掌握度 = 1
        vm.toggleMark("abandon")
        XCTAssertEqual(vm.wordState, .unknown)
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
}
