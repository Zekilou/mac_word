import XCTest
import GRDB
@testable import WordRecitingApp

/// AgentSidecarGenerator 集成测试：真实 sidecar（ScriptedModel 假模型）+ 种子 World。
/// @ai: sidecar 运行环境缺失时 XCTSkip（同 AgentSidecarClientTests）；回退路径用 StubGenerator 验证。
final class AgentSidecarGeneratorTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries!
    private var registry: EntityRegistry!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// 项目根目录（#filePath 上溯：Agent → WordRecitingAppTests → Tests → 根）。
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Agent
            .deletingLastPathComponent()   // WordRecitingAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 项目根
    }

    private var pythonExecutable: URL? {
        let venv = projectRoot
            .appendingPathComponent("external_src/agent-venv/bin/python3.12")
        if FileManager.default.fileExists(atPath: venv.path) { return venv }
        return nil
    }

    private var sidecarScript: URL? {
        let script = projectRoot
            .appendingPathComponent("external_src/agent_sidecar/sidecar.py")
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
    }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
        graph = world.graph
        registry = world.registry
        // abandon（带释义）+ battle（同义词 fight，maps_to B→F）
        try registry.insertNode(id: "A", kind: .lemma, createdAt: epoch)
        try registry.upsertComponent(TextComponent(
            entityId: "A", textA: "abandon", textB: "(v): to leave", language: nil))
        try registry.upsertComponent(LemmaDefinitionComponent(
            entityId: "A", definitionsJson: #"[{"source":"deck:d","definition":"to leave"}]"#))
        try registry.insertNode(id: "B", kind: .lemma, createdAt: epoch)
        try registry.upsertComponent(TextComponent(
            entityId: "B", textA: "battle", textB: nil, language: nil))
        try registry.insertNode(id: "F", kind: .lemma, createdAt: epoch)
        try registry.upsertComponent(TextComponent(
            entityId: "F", textA: "fight", textB: nil, language: nil))
        try registry.insertEdge(id: "e-bf", srcId: "B", dstId: "F", rel: .mapsTo, createdAt: epoch)
        try registry.upsertComponent(EdgeWeightedComponent(
            entityId: "e-bf", weightDouble: 0.9, sourceType: "user"))
    }

    private func makeClient() throws -> AgentSidecarClient {
        guard let python = pythonExecutable, let script = sidecarScript else {
            throw XCTSkip("sidecar 运行环境缺失（venv python / sidecar.py）")
        }
        return AgentSidecarClient(executable: python, scriptPath: script)
    }

    /// 成功路径：sidecar（假模型）生成 → 正文/span/跳过词正确，fallback 不被调用。
    func testGenerateViaSidecarProducesArticle() async throws {
        let client = try makeClient()
        defer { client.stop() }
        let callBox = CallBox()
        let generator = AgentSidecarGenerator(
            client: client,
            spec: AgentSidecarModelSpec(
                model: "qwen2.5", baseURL: "http://localhost:11434/v1", apiKey: "",
                fake: true,
                fakeOutput: "===ARTICLE_START===\nWe should never abandon our dreams. The battle continues every day.\n===ARTICLE_END==="),
            fallback: StubGenerator(onCall: { callBox.called = true }))

        let article = try await generator.generate(
            mode: .generate, sourceText: "科技", targetLemmas: ["A", "B"],
            constraints: GenerationConstraints(), graph: graph)

        XCTAssertEqual(article.generatorId, "agent-sidecar")
        XCTAssertTrue(article.body.contains("abandon"), "正文应含目标词 abandon，实际 \(article.body)")
        XCTAssertTrue(article.body.contains("battle"))
        XCTAssertEqual(article.spans.count, 2, "两个目标词各一个 span")
        XCTAssertTrue(article.skippedWords.isEmpty)
        XCTAssertFalse(callBox.called, "成功路径不应触发回退")
    }

    /// 回退路径：sidecar 坏连接 → 事件流 error → 转交 fallback 生成器。
    func testFallsBackWhenSidecarUnavailable() async throws {
        let client = try makeClient()
        defer { client.stop() }
        let generator = AgentSidecarGenerator(
            client: client,
            spec: AgentSidecarModelSpec(
                model: "x", baseURL: "http://127.0.0.1:1/v1", apiKey: "",
                fake: false),
            fallback: StubGenerator(onCall: {}))

        let article = try await generator.generate(
            mode: .generate, sourceText: "科技", targetLemmas: ["A", "B"],
            constraints: GenerationConstraints(), graph: graph)

        XCTAssertEqual(article.generatorId, "stub", "sidecar 出错应回退 fallback 生成器")
        XCTAssertTrue(article.body.contains("Stub article"))
    }

    /// 无 fallback 时 sidecar 错误应原样抛出（调用方可见错误）。
    func testThrowsWhenNoFallback() async throws {
        let client = try makeClient()
        defer { client.stop() }
        let generator = AgentSidecarGenerator(
            client: client,
            spec: AgentSidecarModelSpec(
                model: "x", baseURL: "http://127.0.0.1:1/v1", apiKey: "",
                fake: false),
            fallback: nil)

        do {
            _ = try await generator.generate(
                mode: .generate, sourceText: "科技", targetLemmas: ["A", "B"],
                constraints: GenerationConstraints(), graph: graph)
            XCTFail("无 fallback 时应抛 sidecar 错误")
        } catch let error as AgentSidecarError {
            _ = error  // 期望的失败形态
        }
    }
}

/// 测试用 stub 生成器：记录是否被调用，返回固定文章。
private struct StubGenerator: ContentGenerator {
    static let identifier = "stub"
    static let tier: QualityTier = .local
    let onCall: @Sendable () -> Void

    func generate(
        mode: GenerationMode,
        sourceText: String?,
        targetLemmas: [EntityID],
        constraints: GenerationConstraints,
        graph: GraphQueries
    ) async throws -> GeneratedArticle {
        onCall()
        return GeneratedArticle(
            body: "Stub article about abandon and battle.",
            spans: [], generatorId: Self.identifier, tier: Self.tier)
    }
}

/// @Sendable 回调的共享标记盒（Swift 6：@Sendable 闭包不能捕获可变局部变量）。
private final class CallBox: @unchecked Sendable {
    var called = false
}
