import XCTest
@testable import WordRecitingApp

/// LlamaServerProcess 端口解析测试（纯函数，不 spawn 真实进程）。
/// @ai: parsePort 是 static 纯函数，覆盖 llama-server 各种输出格式。
final class LlamaServerProcessTests: XCTestCase {

    func testParsePortListeningOnHostPort() {
        // llama-server 常见格式："llama-server: listening on http://127.0.0.1:8080"
        let line = "llama-server: listening on http://127.0.0.1:8080"
        XCTAssertEqual(LlamaServerProcess.parsePort(from: line), 8080)
    }

    func testParsePortListeningOnStarPort() {
        // 格式："listening on *:8080"
        let line = "server: listening on *:8080"
        XCTAssertEqual(LlamaServerProcess.parsePort(from: line), 8080)
    }

    func testParsePortPortEquals() {
        // 格式："port = 8080"
        let line = "llama_server_context: port = 11434"
        XCTAssertEqual(LlamaServerProcess.parsePort(from: line), 11434)
    }

    func testParsePortIgnoresNonListeningLines() {
        // 无 listen/port 关键词的行不匹配（避免误匹配模型参数里的数字）
        let line = "llm_load_print_meta: n_vocab = 128256, n_ctx_train = 32768"
        XCTAssertNil(LlamaServerProcess.parsePort(from: line))
    }

    func testParsePortHighPort() {
        // 系统分配的高端口（5 位数）
        let line = "server: listening on http://127.0.0.1:54321"
        XCTAssertEqual(LlamaServerProcess.parsePort(from: line), 54321)
    }

    func testParsePortEmptyLine() {
        XCTAssertNil(LlamaServerProcess.parsePort(from: ""))
        XCTAssertNil(LlamaServerProcess.parsePort(from: "   "))
    }
}
