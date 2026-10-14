import XCTest
@testable import WordRecitingApp

/// Embedding RAG 选锚相关测试：GloVe 加载 / 余弦选锚 / 语义锚点合成 / 词库数据兜底。
/// @ai: 全部 mock——注入手写小词表（test stub），不依赖真实 GloVe 文件（用户下载后由转换脚本生成）。
final class EmbeddingRAGTests: XCTestCase {

    // MARK: - 手写词表（同向量空间：维度 4，人工设计语义方向）

    /// 测试用词表：battle/fight/war 近义（同方向），abandon/leave/give-up 近义，cat 独立。
    private func makeTestProvider() -> GloVeEmbeddingProvider {
        let words: [(String, [Float])] = [
            ("battle", [1.0, 0.0, 0.0, 0.0]),
            ("fight", [0.9, 0.1, 0.0, 0.0]),
            ("war", [0.8, 0.2, 0.0, 0.0]),
            ("abandon", [0.0, 0.0, 1.0, 0.0]),
            ("leave", [0.1, 0.0, 0.9, 0.0]),
            ("give", [0.0, 0.0, 0.8, 0.2]),
            ("up", [0.0, 0.0, 0.8, 0.2]),
            ("cat", [0.0, 1.0, 0.0, 0.0]),
            ("dream", [0.0, 0.5, 0.0, 0.5]),
        ]
        var data = Data()
        func i32(_ v: Int32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        func f32(_ v: Float) {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        i32(4)  // dim
        i32(Int32(words.count))  // count
        for (w, vec) in words {
            let bytes = Array(w.utf8)
            i32(Int32(bytes.count))
            data.append(contentsOf: bytes)
            for v in vec { f32(v) }
        }
        return try! GloVeEmbeddingProvider(data: data)
    }

    /// 空数据库 World（语义锚点查询用）。
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    // MARK: - GloVe 加载

    func testGloVeProviderLoadsAndQueries() async {
        let p = makeTestProvider()
        XCTAssertEqual(p.dimension, 4)
        let battle = await p.vector(for: "battle")
        XCTAssertEqual(battle?[0], 1.0)
        let upper = await p.vector(for: "BATTLE")
        XCTAssertEqual(upper?[0], 1.0, "大小写不敏感")
        let oov = await p.vector(for: "nonexistent")
        XCTAssertNil(oov, "OOV 返回 nil")
    }

    func testGloVeProviderRejectsTruncatedData() {
        XCTAssertThrowsError(try GloVeEmbeddingProvider(data: Data([0x01]))) { error in
            XCTAssertTrue(error is EmbeddingLoadError)
        }
    }

    /// 内置资源真实加载：glove50d.bin 已随 app bundle 分发，能查到高频词。
    /// @ai: 资源打包正确性验证（非 LLM 推理，成本低）。
    ///      `glove50d.bin` 是**本地生成产物**（按 .gitignore 不入库），全新克隆里必然不存在；
    ///      此时应 XCTSkip 而不是 XCTFail——否则「克隆即可跑测试」被打破。
    ///      要验证资源打包，请先在本地生成 glove50d.bin（见备忘录 convert_glove 步骤）。
    func testBundledGloVeLoadsRealFile() async throws {
        guard let provider = GloVeEmbeddingProvider() else {
            throw XCTSkip("glove50d.bin 未生成（本地资源，不入库）；跳过内置词向量加载验证")
        }
        XCTAssertEqual(provider.dimension, 50)
        let the = await provider.vector(for: "the")
        XCTAssertNotNil(the, "高频词 the 应在词表内")
        let battle = await provider.vector(for: "battle")
        XCTAssertNotNil(battle)
        let oov = await provider.vector(for: "zzzzqx")
        XCTAssertNil(oov, "生僻词 OOV 返回 nil")
    }

    // MARK: - 余弦相似度

    func testCosineSimilarity() {
        XCTAssertEqual(EmbeddingMath.cosine([1, 0], [1, 0]), 1.0, accuracy: 0.001)
        XCTAssertEqual(EmbeddingMath.cosine([1, 0], [0, 1]), 0.0, accuracy: 0.001)
        XCTAssertEqual(EmbeddingMath.cosine([1, 0], [-1, 0]), -1.0, accuracy: 0.001)
        XCTAssertEqual(EmbeddingMath.cosine([], []), 0.0, "空向量返回 0")
    }

    func testAverageVectorOfText() async {
        let p = makeTestProvider()
        let v = await EmbeddingMath.averageVector(of: "battle and fight", provider: p)
        XCTAssertNotNil(v)
        XCTAssertEqual(v![0], 0.95, accuracy: 0.001, "battle+fight 平均 = 1.0 与 0.9 的均值")
    }

    // MARK: - 语义锚点合成（词库数据）

    /// 词在表内：直接命中。
    func testComposerHitsTableFirst() async {
        let p = makeTestProvider()
        let composer = SemanticAnchorComposer(provider: p, llm: nil, graph: world.graph)
        let v = await composer.vector(for: "battle", lemmaId: "lemma-1")
        XCTAssertEqual(v?[0], 1.0)
    }

    /// 词不在表内：用词库释义 + maps_to 同义词合成（同义词在表内 → 平均向量）。
    func testComposerUsesLexiconWhenOOV() async throws {
        let p = makeTestProvider()
        // 建 lemma：skirmish（OOV），定义含 battle/fight（表内）
        let now = Date()
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
            ],
            textComponents: [TextComponent(
                entityId: "lemma-1", textA: "skirmish", textB: "a small battle or fight",
                language: "en")],
            deckMetas: [DeckMetaComponent(
                entityId: "deck-1", name: "T", sourceKind: "csv",
                sourcePath: nil, importedAt: now)],
            edges: [], failures: [])
        try world.run(ImportSystem(), context: batch)

        let composer = SemanticAnchorComposer(provider: p, llm: nil, graph: world.graph)
        let v = await composer.vector(for: "skirmish", lemmaId: "lemma-1")
        XCTAssertNotNil(v, "应通过词库释义合成向量")
        // 释义 battle/fight 方向在 dim0 高 → 合成的向量 dim0 应显著
        XCTAssertGreaterThan(v![0], 0.5, "词库释义应把 skirmish 推向 battle 方向")
    }

    /// 词与词库都没有 → nil（不硬塞，调用方 skip）。
    func testComposerReturnsNilWhenNothing() async {
        let p = makeTestProvider()
        let composer = SemanticAnchorComposer(provider: p, llm: nil, graph: world.graph)
        let v = await composer.vector(for: "zzzzyqqq", lemmaId: "lemma-missing")
        XCTAssertNil(v)
    }

    // MARK: - Embedding 余弦选锚

    /// 语义选锚：词 battle 应选中含 battle/fight 语义的句子（而非 cat 句）。
    func testMatcherPicksSemanticallyClosestSentence() async {
        let p = makeTestProvider()
        let composer = SemanticAnchorComposer(provider: p, llm: nil, graph: world.graph)
        let matcher = EmbeddingAnchorMatcher(composer: composer, provider: p)
        let sentences = [
            "The cat sat on the mat.",
            "The soldiers prepared for the war.",
            "He made a decision to leave.",
        ]
        let matches = await matcher.match(words: ["battle": "l1"], sentences: sentences)
        XCTAssertEqual(matches.first?.sentenceIndex, 1, "battle 应选 war 句（语义最近）")
    }

    /// 低于阈值 → skip（sentenceIndex = -1），不硬塞。
    func testMatcherSkipsWhenBelowThreshold() async {
        let p = makeTestProvider()
        let composer = SemanticAnchorComposer(provider: p, llm: nil, graph: world.graph)
        let matcher = EmbeddingAnchorMatcher(composer: composer, provider: p, threshold: 0.99)
        let matches = await matcher.match(
            words: ["battle": "l1"],
            sentences: ["The cat sat quietly."])
        XCTAssertEqual(matches.first?.sentenceIndex, -1, "阈值过高应判定融不进去")
    }

    /// 同句去重：两词都选中同一句 → 高分者占用，低分者顺延/skip。
    func testMatcherDeconflictsSharedSentence() async {
        let p = makeTestProvider()
        let composer = SemanticAnchorComposer(provider: p, llm: nil, graph: world.graph)
        let matcher = EmbeddingAnchorMatcher(composer: composer, provider: p)
        let anchors = [
            EmbeddingAnchor(word: "battle", sentenceIndex: 1, score: 0.9),
            EmbeddingAnchor(word: "war", sentenceIndex: 1, score: 0.5),
            EmbeddingAnchor(word: "cat", sentenceIndex: 2, score: 0.8),
        ]
        let deconflicted = matcher.deconflict(anchors)
        // battle(0.9) 占句 1；war(0.5) 冲突 → -1；cat 占句 2
        let war = deconflicted.first { $0.word == "war" }
        XCTAssertEqual(war?.sentenceIndex, -1)
    }
}
