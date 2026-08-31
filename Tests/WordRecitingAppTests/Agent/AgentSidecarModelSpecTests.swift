import XCTest
@testable import WordRecitingApp

/// Task 5：AgentSidecarModelSpec 序列化契约（与 sidecar.py / generator.py 的 params.model 对齐）。
final class AgentSidecarModelSpecTests: XCTestCase {

    func testJSONObjectCarriesModelFields() {
        let spec = AgentSidecarModelSpec(
            model: "deepseek-v4-flash",
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "sk-x",
            isThinking: true,
            contextWindow: 8192,
            temperature: 0.5)
        let obj = spec.jsonObject()
        XCTAssertEqual(obj["model"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(obj["base_url"] as? String, "https://api.deepseek.com/v1")
        XCTAssertEqual(obj["api_key"] as? String, "sk-x")
        XCTAssertEqual(obj["is_thinking"] as? Bool, true)
        XCTAssertEqual(obj["context_window"] as? Int, 8192)
        XCTAssertEqual(obj["temperature"] as? Double, 0.5)
        XCTAssertNil(obj["fake"], "非测试模式不携带 fake 钩子")
    }

    func testJSONObjectCarriesFakeHook() {
        let spec = AgentSidecarModelSpec(
            model: "qwen2.5",
            baseURL: "http://localhost:11434/v1",
            apiKey: "",
            fake: true,
            fakeOutput: "===ARTICLE_START===\nA test body.\n===ARTICLE_END===")
        let obj = spec.jsonObject()
        XCTAssertEqual(obj["fake"] as? Bool, true)
        XCTAssertEqual(
            obj["fakeOutput"] as? String,
            "===ARTICLE_START===\nA test body.\n===ARTICLE_END===")
    }
}
