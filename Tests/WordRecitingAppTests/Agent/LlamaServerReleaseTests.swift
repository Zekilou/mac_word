import XCTest
@testable import WordRecitingApp

/// LlamaServerRelease URL 构造 + LlamaServerLifecycle 枚举测试。
/// @ai: 不测网络（latestTag 走真实 GitHub API，集成测试另写）；只测纯函数 URL 构造。
final class LlamaServerReleaseTests: XCTestCase {

    func testDownloadURLForKnownTag() throws {
        let url = try XCTUnwrap(LlamaServerRelease.downloadURL(tag: "b10453"))
        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/ggml-org/llama.cpp/releases/download/b10453/llama-b10453-bin-macos-arm64.tar.gz")
    }

    func testDownloadURLContainsTagAndPlatform() throws {
        let url = try XCTUnwrap(LlamaServerRelease.downloadURL(tag: "b9999"))
        let s = url.absoluteString
        XCTAssertTrue(s.contains("/b9999/"), "URL 路径含 tag")
        XCTAssertTrue(s.contains("llama-b9999-bin-macos-arm64.tar.gz"), "文件名含 tag + macOS arm64")
    }

    func testLifecycleLabels() {
        XCTAssertEqual(LlamaServerLifecycle.persistent.label, "常驻（启动即加载，零延迟）")
        XCTAssertEqual(LlamaServerLifecycle.perGenerate.label, "按生成启停（省内存，启动延迟）")
        XCTAssertEqual(LlamaServerLifecycle.idleTimeout.label, "闲置超时停（平衡）")
    }

    func testLifecycleAllCasesHasThree() {
        XCTAssertEqual(LlamaServerLifecycle.allCases.count, 3)
        XCTAssertTrue(LlamaServerLifecycle.allCases.contains(.persistent))
        XCTAssertTrue(LlamaServerLifecycle.allCases.contains(.perGenerate))
        XCTAssertTrue(LlamaServerLifecycle.allCases.contains(.idleTimeout))
    }

    func testIdleTimeoutSecondsIs5Minutes() {
        XCTAssertEqual(LlamaServerLifecycle.idleTimeoutSeconds, 300)
    }
}
