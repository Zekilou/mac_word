import XCTest
import GRDB
@testable import WordRecitingApp

/// 进程内引擎真实推理测试（llama.cpp / LlamaSwift）。
/// 需要模型目录（~/Library/Application Support/WordRecitingApp/models）存在 .gguf 文件，
/// 可通过设置页「进程内模型」导入或从 Ollama 提取；无模型则跳过（不视为失败）。
/// @ai: 真实推理较慢（模型加载 + 生成），只做冒烟：输出非空即可。
final class LlamaCPPProcessLocalTests: XCTestCase {

    func testProcessLocalInferenceProducesOutput() async throws {
        let store = ModelStore()
        let models = store.discoveredModels()
        guard !models.isEmpty else {
            throw XCTSkip("模型目录无 GGUF 文件。请先在设置页「进程内模型」导入 .gguf 或从 Ollama 提取。")
        }

        let client = LlamaCPPClient(modelPath: models[0].url.path)
        let prompt = "Say hello and introduce yourself in one short English sentence."
        let tokenCount = TokenCountBox()
        let output = try await client.stream(
            prompt: prompt, maxTokens: 50, temperature: 0.7) { _ in
            tokenCount.value += 1
        }
        XCTAssertFalse(output.isEmpty, "进程内推理应产生非空输出")
        XCTAssertGreaterThan(tokenCount.value, 0, "流式应产生逐 token 回调")
        // 回归：chat template 已应用，输出不应回显提示词，而是直接作答。
        XCTAssertFalse(output.hasPrefix(prompt),
                       "输出不应回显提示词，实际: \(output.prefix(120))")
    }

    func testProcessLocalMissingModelFileThrows() async throws {
        let client = LlamaCPPClient(modelPath: "/nonexistent/model.gguf")
        do {
            _ = try await client.complete(prompt: "hi", maxTokens: 5, temperature: 0)
            XCTFail("模型文件不存在应抛错")
        } catch {
            // LlamaEngine.InferenceError.modelLoadFailed 或底层错误均可接受
        }
    }

    /// 回归：自查 pass 会把整篇文章嵌进提示词（>512 token）。
    /// 提示词超过 n_batch 时必须分片解码，否则 llama.cpp 直接 abort 崩溃。
    func testProcessLocalLongPromptDoesNotAbort() async throws {
        let store = ModelStore()
        let models = store.discoveredModels()
        guard !models.isEmpty else {
            throw XCTSkip("模型目录无 GGUF 文件")
        }
        // ≈960 词 ≈1200 token：> n_batch(512) 且 < n_ctx(2048)
        let longPrompt = Array(
            repeating: "Technology is changing the way we live and work every single day. ",
            count: 60).joined()
        let client = LlamaCPPClient(modelPath: models[0].url.path)
        let output = try await client.complete(prompt: longPrompt, maxTokens: 20, temperature: 0)
        XCTAssertFalse(output.isEmpty, "长提示词分片解码应正常生成")
    }
}

/// 线程安全计数器（流式 token 回调计数）。
private final class TokenCountBox: @unchecked Sendable {
    var value = 0
}
