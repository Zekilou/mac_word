import XCTest
@testable import WordRecitingApp

/// Agent sidecar JSONL 协议解析测试。
/// @ai: 契约与 external_src/agent_sidecar/sidecar.py 对齐；新增事件两侧同步后在此补用例。
final class AgentSidecarProtocolTests: XCTestCase {

    // MARK: - 事件解析

    func testParsesPong() {
        let e = AgentSidecarProtocol.Event.parse(#"{"id":1,"type":"pong"}"#)
        XCTAssertEqual(e, .pong(id: 1))
    }

    func testParsesErrorWithAndWithoutID() {
        XCTAssertEqual(
            AgentSidecarProtocol.Event.parse(#"{"id":2,"type":"error","code":"not_implemented","message":"x"}"#),
            .error(id: 2, code: "not_implemented", message: "x"))
        // bad_request 无 id（坏 JSON 无法关联请求）
        XCTAssertEqual(
            AgentSidecarProtocol.Event.parse(#"{"type":"error","code":"bad_request","message":"boom"}"#),
            .error(id: nil, code: "bad_request", message: "boom"))
    }

    func testParsesStage() {
        XCTAssertEqual(
            AgentSidecarProtocol.Event.parse(#"{"id":3,"type":"stage","stage":"generating"}"#),
            .stage(id: 3, stage: .generating))
        XCTAssertEqual(
            AgentSidecarProtocol.Event.parse(#"{"id":3,"type":"stage","stage":"strategy"}"#),
            .stage(id: 3, stage: .strategy))
        // 未知阶段 → nil（防误认）
        XCTAssertNil(AgentSidecarProtocol.Event.parse(#"{"id":3,"type":"stage","stage":"nope"}"#))
    }

    func testParsesThought() {
        let e = AgentSidecarProtocol.Event.parse(
            #"{"id":4,"type":"thought","thoughtID":"strategy","kind":"strategy","message":"m","detail":"d","status":"done"}"#)
        XCTAssertEqual(e, .thought(id: 4, thought: GenThought(
            id: "strategy", kind: .strategy, message: "m", detail: "d", status: .done)))
    }

    func testParsesToken() {
        XCTAssertEqual(
            AgentSidecarProtocol.Event.parse(#"{"id":4,"type":"token","text":"hello"}"#),
            .token(id: 4, text: "hello"))
    }

    func testParsesResultWithSkippedWords() {
        let line = #"{"id":5,"type":"result","article":"The article.","skippedWords":[{"word":"abandon","reason":"no natural fit"}]}"#
        let e = AgentSidecarProtocol.Event.parse(line)
        XCTAssertEqual(e, .result(
            id: 5, article: "The article.",
            skippedWords: [SkippedWord(word: "abandon", reason: "no natural fit")]))
    }

    func testIgnoresMalformedLines() {
        XCTAssertNil(AgentSidecarProtocol.Event.parse(""))
        XCTAssertNil(AgentSidecarProtocol.Event.parse("not-json"))
        XCTAssertNil(AgentSidecarProtocol.Event.parse(#"{"type":"unknown"}"#))
        XCTAssertNil(AgentSidecarProtocol.Event.parse(#"{"id":1,"type":"pong"}"# + "x"), "尾随字符应拒绝")
    }

    // MARK: - 请求构造

    func testBuildsRequestLine() {
        let line = AgentSidecarProtocol.request(id: 1, method: "ping")
        XCTAssertTrue(line.contains(#""id":1"#))
        XCTAssertTrue(line.contains(#""method":"ping""#))
        let withParams = AgentSidecarProtocol.request(
            id: 2, method: "generate",
            params: ["maxWords": 100, "theme": "科技"])
        XCTAssertTrue(withParams.contains(#""maxWords":100"#))
        XCTAssertTrue(withParams.contains(#""theme":"科技""#))
    }
}
