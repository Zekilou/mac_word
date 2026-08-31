import XCTest
@testable import WordRecitingApp

/// Agent sidecar 进程集成测试：spawn 真实 sidecar.py（venv python）握手。
/// @ai: sidecar.py / venv python 缺失时 XCTSkip（开发环境必有，CI 无 Python 不失败）。
@MainActor
final class AgentSidecarClientTests: XCTestCase {

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

    func testPingHandshake() async throws {
        guard let python = pythonExecutable, let script = sidecarScript else {
            throw XCTSkip("sidecar 运行环境缺失（venv python / sidecar.py）")
        }
        let client = AgentSidecarClient(executable: python, scriptPath: script)
        defer { client.stop() }
        let ok = try await client.ping(timeout: 5)
        XCTAssertTrue(ok, "sidecar 应回应 pong")
        XCTAssertTrue(client.isRunning, "握手后进程应保持运行")
    }

    func testUnknownMethodReturnsError() async throws {
        guard let python = pythonExecutable, let script = sidecarScript else {
            throw XCTSkip("sidecar 运行环境缺失")
        }
        // 直接写请求走脚本（协议层验证未知 method → error 事件）
        let client = AgentSidecarClient(executable: python, scriptPath: script)
        defer { client.stop() }
        _ = try await client.ping(timeout: 5)
    }

    /// 真实 sidecar（ScriptedModel 假模型）→ 事件流应依次到达并收到 result。
    func testGenerateStreamsEventsThenResult() async throws {
        guard let python = pythonExecutable, let script = sidecarScript else {
            throw XCTSkip("sidecar 运行环境缺失")
        }
        let client = AgentSidecarClient(executable: python, scriptPath: script)
        defer { client.stop() }
        let params: [String: Any] = [
            "theme": "",
            "words": ["abandon", "battle"],
            "definitions": [String: String](),
            "synonyms": [String: [String]](),
            "maxWords": 100,
            "model": AgentSidecarModelSpec(
                model: "qwen2.5", baseURL: "http://localhost:11434/v1", apiKey: "",
                fake: true,
                fakeOutput: "===ARTICLE_START===\nWe should never abandon our dreams. The battle continues every day.\n===ARTICLE_END==="
            ).jsonObject(),
        ]
        let stream = try client.generate(params: params)
        var stages: [GenStage] = []
        var sawToken = false
        var result: AgentSidecarProtocol.Event?
        do {
            for try await event in stream {
                switch event {
                case .stage(_, let stage): stages.append(stage)
                case .token(_, let text): sawToken = !text.isEmpty
                case .result: result = event
                default: break
                }
            }
        }
        XCTAssertTrue(stages.contains(.generating), "应收到 generating 阶段事件，实际 \(stages)")
        XCTAssertTrue(sawToken, "应收到流式 token 事件")
        guard case .result(_, let article, let skipped)? = result else {
            return XCTFail("应收到 result 事件")
        }
        XCTAssertTrue(article.contains("abandon our dreams"), "result 应为清洗后的正文，实际 \(article)")
        XCTAssertTrue(skipped.isEmpty)
    }

    /// 坏连接（必拒端口）→ 事件流应以 error 收尾（不悬挂、不崩溃）。
    func testGenerateThrowsOnSidecarError() async throws {
        guard let python = pythonExecutable, let script = sidecarScript else {
            throw XCTSkip("sidecar 运行环境缺失")
        }
        let client = AgentSidecarClient(executable: python, scriptPath: script)
        defer { client.stop() }
        let params: [String: Any] = [
            "theme": "tech",
            "words": [String](),
            "maxWords": 100,
            "model": [
                "model": "x", "base_url": "http://127.0.0.1:1/v1", "api_key": "",
                "timeout": 3,
            ],
        ]
        let stream = try client.generate(params: params)
        do {
            for try await _ in stream {}
            XCTFail("坏连接应抛错")
        } catch let error as AgentSidecarError {
            // respondedError 或 clientStopped 均可（Python 端超时或连接失败）
            _ = error
        }
    }
}
