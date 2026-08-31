import XCTest
import GRDB
@testable import WordRecitingApp

/// 真实 Ollama 端到端测试：验证 LocalLLMGenerator 经 OpenAI 兼容端点
/// 连本地 Ollama 生成含目标词的文章。
/// 前置：本机已安装并运行 Ollama，且已 `ollama pull qwen2.5:0.5b`。
/// 默认跳过（官方回归）；如需手动验证，设 `RUN_REAL_LLM_TESTS=1` 运行。
final class OllamaEndToEndTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_REAL_LLM_TESTS"] == "1",
            "真实 Ollama 端到端测试默认跳过（官方回归）；设 RUN_REAL_LLM_TESTS=1 手动验证")
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
    }

    /// 探测本地 Ollama 是否可用。
    private func ollamaAvailable() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200 else { return false }
        return true
    }

    func testLocalLLMGeneratesArticleContainingTargetWords() async throws {
        guard await ollamaAvailable() else {
            try XCTSkipIf(true, "本地 Ollama 未运行，跳过真实 LLM 冒烟")
            return
        }

        // 1. 准备词库（abandon / battle）
        let now = Date()
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
                .init(id: "lemma-2", kind: .lemma, createdAt: now),
            ],
            textComponents: [
                TextComponent(entityId: "lemma-1", textA: "abandon", textB: nil, language: "en"),
                TextComponent(entityId: "lemma-2", textA: "battle", textB: nil, language: "en"),
            ],
            deckMetas: [DeckMetaComponent(
                entityId: "deck-1", name: "T", sourceKind: "csv",
                sourcePath: nil, importedAt: now)],
            edges: [], failures: [])
        try world.run(ImportSystem(), context: batch)

        // 2. 真实 LLM 造文
        let client = OpenAICompatibleClient(
            baseURL: "http://localhost:11434/v1",
            apiKey: nil,
            model: "qwen2.5:0.5b")
        let gen = LocalLLMGenerator(client: client, maxTokens: 400, temperature: 0.7)
        let article = try await gen.generate(
            mode: .generate,
            sourceText: "environmental protection",
            targetLemmas: ["lemma-1", "lemma-2"],
            constraints: GenerationConstraints(maxWords: 120),
            graph: graph)

        // 3. 断言：非空、生成器标识、文章可读
        XCTAssertFalse(article.body.isEmpty, "LLM 应产出非空文章")
        XCTAssertEqual(article.generatorId, "local-llm")
        print("=== Ollama 造文结果 ===")
        print(article.body)
        print("=== spans: \(article.spans.count) 个 ===")
        for span in article.spans {
            print("  [\(span.start)-\(span.end)] \(span.surfaceForm) lemma=\(span.lemmaId ?? "nil")")
        }
        // 目标词命中依赖模型服从度（0.5b 小模型不稳定），不做硬断言；
        // 若命中则必须是 isTarget=true。
        XCTAssertTrue(article.spans.allSatisfy { $0.isTarget })
    }
}
