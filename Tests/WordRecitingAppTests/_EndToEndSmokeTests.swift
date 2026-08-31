import XCTest
import GRDB
@testable import WordRecitingApp

/// 真实端到端冒烟测试：
/// 1. 导入 external_src/TOEFL 400 .apkg 文件
/// 2. 通过 SynonymSystem 建立 abandon→forsake 用户同义词
/// 3. RuleBasedGenerator 改写："I will abandon this project." → "I will forsake this project."
final class EndToEndSynonymSmokeTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
    }

    func testImportTOEFLThenAddAbandonForsakeSynonymThenRewrite() async throws {
        // 0. 定位 TOEFL .apkg 文件（项目根目录/external_src）
        let fm = FileManager.default
        // 从当前源文件路径向上定位项目根：
        // #file = .../Tests/WordRecitingAppTests/_EndToEndSmokeTests.swift → 上 3 级 = project root
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let toeflPath = projectRoot.appendingPathComponent("external_src")
            .appendingPathComponent("400_must_have_words_for_the_TOEFL_.apkg")
        guard fm.fileExists(atPath: toeflPath.path) else {
            // 文件不在本环境：跳过该冒烟测试，不视为失败
            try XCTSkipIf(true, "TOEFL .apkg 未找到，跳过端到端冒烟：\(toeflPath.path)")
            return
        }

        // MARK: - Step 1: 导入 TOEFL .apkg
        let importer = AnkiImporter()
        let batch = try await importer.readNodes(from: toeflPath) { @Sendable _ in }
        XCTAssertTrue(batch.failures.isEmpty, "TOEFL 导入不应有 failures，实际: \(batch.failures)")
        XCTAssertGreaterThan(batch.nodes.count, 400, "TOEFL 应有 400+ nodes")

        try world.run(ImportSystem(), context: batch)

        // 确认有 decks 与 lemmas
        let decks = try graph.allDecks()
        XCTAssertGreaterThanOrEqual(decks.count, 1)
        let firstDeck = try XCTUnwrap(decks.first)
        XCTAssertGreaterThan(firstDeck.cardCount, 300)

        // MARK: - Step 2: 从词库取 2 个实际存在的词（a 开头 + b 开头，避免相同）

        /// 从 "abandon[ə'bændən]" / "happy (adj)" 这种尾巴形式中提取前缀纯单词。
        func extractPlainWord(_ raw: String) -> String {
            var end = raw.startIndex
            while end < raw.endIndex, raw[end].isLetter || raw[end] == "-" || raw[end] == "'" {
                raw.formIndex(after: &end)
            }
            return String(raw[..<end]).trimmingCharacters(in: .whitespaces)
        }

        let aCands = try graph.searchLemmas(prefix: "a", limit: 20)
        let bCands = try graph.searchLemmas(prefix: "b", limit: 20)
        guard !aCands.isEmpty, !bCands.isEmpty else {
            try XCTSkipIf(true, "词库中没找到 a 开头或 b 开头的 lemma，无法完成冒烟")
            return
        }
        let candA = aCands[0]
        let candB = bCands[0]
        let wordA = extractPlainWord(candA.text)
        let wordB = extractPlainWord(candB.text)
        guard !wordA.isEmpty, !wordB.isEmpty else {
            try XCTSkipIf(true, "无法从 lemma 文本提取干净单词: \(candA.text) / \(candB.text)")
            return
        }
        // 通过 findLemmaId 拿到真正的 lemma id（与 RuleBasedGenerator 同一条路径）
        let lemmaA = try XCTUnwrap(graph.findLemmaId(byTextA: wordA),
                                   "应能用干净单词 \(wordA) 反查到 lemma id")
        let lemmaB = try XCTUnwrap(graph.findLemmaId(byTextA: wordB),
                                   "应能用干净单词 \(wordB) 反查到 lemma id")
        XCTAssertNotEqual(lemmaA, lemmaB)
        print("选定 lemmaA: \(wordA) -> \(lemmaA) (\(candA.text))")
        print("选定 lemmaB: \(wordB) -> \(lemmaB) (\(candB.text))")

        // MARK: - Step 3: 建立 A → B 用户同义词（走 SynonymSystem）
        try world.run(SynonymSystem(), context: .add(
            from: lemmaA, to: lemmaB, weight: 1.0, sourceType: "user"))

        // 验证 GraphQueries.synonyms 能读到
        let synsOfA = try graph.synonyms(of: lemmaA)
        let bSyn = try XCTUnwrap(synsOfA.first(where: { $0.lemmaId == lemmaB }))
        XCTAssertEqual(bSyn.weight ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(bSyn.sourceType, "user")
        // 验证 listAllSynonymMappings
        let allMaps = try graph.listAllSynonymMappings()
        XCTAssertTrue(allMaps.contains(where: {
            $0.fromLemmaId == lemmaA && $0.toLemmaId == lemmaB
        }))

        // MARK: - Step 4: 改写验证
        // 保持大小写：如果源文是 wordA 小写，RuleBasedGenerator 保大小写替换为 wordB
        let sourceText = "I will \(wordA) this project and never look back."
        let expectedBody = "I will \(wordB) this project and never look back."
        let gen = RuleBasedGenerator()
        // 目标词指定为 lemmaB（想把源文中的 wordA 替换为 wordB）
        let result = try await gen.generate(
            mode: .rewrite,
            sourceText: sourceText,
            targetLemmas: [lemmaB],
            constraints: GenerationConstraints(synonymDistance: 0.4),
            graph: graph)

        // 核心断言：wordA 被替换为 wordB
        XCTAssertEqual(result.body, expectedBody,
                       "\(wordA) 应通过 maps_to 同义词被替换为 \(wordB)")

        // 至少有 1 个 span 对应 target lemma (lemmaB)
        let targetSpans = result.spans.filter { $0.lemmaId == lemmaB }
        XCTAssertGreaterThanOrEqual(targetSpans.count, 1)
        let sp = try XCTUnwrap(targetSpans.first)
        // 表面形式应与 wordB 大小写一致（源文 wordA 是小写，因此 wordB 也小写）
        XCTAssertEqual(sp.surfaceForm.lowercased(), wordB.lowercased())
        XCTAssertEqual(sp.isTarget, true)
        XCTAssertEqual(sp.weight ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(sp.sourceType, "user")

        // MARK: - Step 5: 落库验证（ContentGenSystem 写入后仍能从历史回读）
        try world.run(ContentGenSystem(), context: ContentGenContext(
            article: result,
            targetLemmas: [lemmaB],
            sourceText: sourceText,
            topic: "E2E smoke"))
        let recent = try graph.recentArticles(mode: .rewrite, limit: 10)
        let latest = try XCTUnwrap(recent.first, "应有刚写入的 rewrite 历史")
        let stored = try XCTUnwrap(graph.loadArticle(id: latest.id))
        XCTAssertEqual(stored.body, result.body, "回读文章正文应与生成一致")
        let storedTargets = stored.spans.filter { $0.lemmaId == lemmaB }
        XCTAssertGreaterThanOrEqual(storedTargets.count, 1,
                                     "回读 span 应包含 lemmaB 的 highlighted_in 关系")
    }
}
