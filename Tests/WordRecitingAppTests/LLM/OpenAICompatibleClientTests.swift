import XCTest
@testable import WordRecitingApp

/// OpenAICompatibleClient 思考型模型适配测试：
/// thinking 参数 / 流式跳 reasoning_content / thinkingOnly / 探测 / 静默超时。
final class OpenAICompatibleClientTests: XCTestCase {

    /// 带 stub 会话的客户端（测试注入 StubURLProtocol）。
    private func makeClient(
        isThinking: Bool = false,
        thinkingBudget: Int = ThinkingBudget.default
    ) -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeURLProtocol.self]
        return OpenAICompatibleClient(
            baseURL: "https://api.test.local/v1", apiKey: "sk-test", model: "deepseek-v4-flash",
            isThinking: isThinking, thinkingBudget: thinkingBudget,
            session: URLSession(configuration: config))
    }

    private static let okResponse = HTTPURLResponse(
        url: URL(string: "https://api.test.local/v1/chat/completions")!,
        statusCode: 200, httpVersion: nil, headerFields: nil)!

    // MARK: - 请求体构造

    /// URLSession 可能把 httpBody 移到 httpBodyStream；统一从两处读取。
    private static func bodyData(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// 思考型客户端：请求体带 thinking 开关 + thinking_budget，不传 temperature；max_tokens 加思考预算。
    func testThinkingClientSendsThinkingParams() async throws {
        var capturedBody: [String: Any] = [:]
        ProbeURLProtocol.handler = { request in
            let data = try XCTUnwrap(Self.bodyData(of: request))
            capturedBody = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (Self.okResponse, Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        }
        let client = makeClient(isThinking: true, thinkingBudget: 2048)
        _ = try await client.complete(prompt: "hi", maxTokens: 600, temperature: 0.7)

        let thinking = capturedBody["thinking"] as? [String: String]
        XCTAssertEqual(thinking?["type"], "enabled")
        XCTAssertEqual(capturedBody["thinking_budget"] as? Int, 2048)
        // 思考模式不支持 temperature → 不传
        XCTAssertNil(capturedBody["temperature"])
        // 正文目标 600 + 思考预算 2048
        XCTAssertEqual(capturedBody["max_tokens"] as? Int, 600 + 2048)
    }

    /// 普通客户端：传 temperature，不传 thinking。
    func testPlainClientSendsTemperatureOnly() async throws {
        var capturedBody: [String: Any] = [:]
        ProbeURLProtocol.handler = { request in
            let data = try XCTUnwrap(Self.bodyData(of: request))
            capturedBody = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (Self.okResponse, Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        }
        let client = makeClient(isThinking: false)
        _ = try await client.complete(prompt: "hi", maxTokens: 600, temperature: 0.7)

        XCTAssertNil(capturedBody["thinking"])
        XCTAssertEqual(capturedBody["temperature"] as? Double, 0.7)
        XCTAssertEqual(capturedBody["max_tokens"] as? Int, 600)
    }

    // MARK: - 流式：跳过 reasoning_content

    /// 思考型流式：先吐 reasoning_content（content null），后吐 content → onToken 只收正文。
    func testStreamSkipsReasoningContent() async throws {
        ProbeURLProtocol.handler = { _ in
            let sse = """
            data: {"choices":[{"delta":{"reasoning_content":"Let me plan..."}}]}

            data: {"choices":[{"delta":{"reasoning_content":"more thinking"}}]}

            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"content":" world"}}]}

            data: [DONE]

            """
            return (Self.okResponse, Data(sse.utf8))
        }
        let client = makeClient(isThinking: true)
        let tokens = TokenBox()
        let text = try await client.stream(prompt: "hi", maxTokens: 100, temperature: 0.3) { token in
            tokens.values.append(token)
        }
        XCTAssertEqual(tokens.values, ["Hello", " world"], "reasoning 段不应产生正文 token")
        XCTAssertEqual(text, "Hello world")
    }

    /// 思考型流式：只有 reasoning_content、无 content → 自动降级重试（关闭思考）；重试仍无正文 → emptyResponse。
    func testStreamThrowsThinkingOnlyWhenNoContent() async throws {
        ProbeURLProtocol.handler = { _ in
            let sse = """
            data: {"choices":[{"delta":{"reasoning_content":"thinking but no answer"}}]}

            data: [DONE]

            """
            return (Self.okResponse, Data(sse.utf8))
        }
        let client = makeClient(isThinking: true)
        do {
            _ = try await client.stream(prompt: "hi", maxTokens: 100, temperature: 0.3) { _ in }
            XCTFail("应抛错")
        } catch LLMClientError.emptyResponse {
            // 降级后的普通请求仍无正文 → emptyResponse（不再 thinkingOnly）
        } catch {
            XCTFail("应为 emptyResponse，实际 \(error)")
        }
    }

    /// 思考型 complete：思考后正文空 → 自动重试一次（关闭思考）→ 拿到正文。
    func testCompleteRetriesWithoutThinkingOnThinkingOnly() async throws {
        var callCount = 0
        var secondBody: [String: Any] = [:]
        ProbeURLProtocol.handler = { request in
            callCount += 1
            let data = try XCTUnwrap(Self.bodyData(of: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if callCount == 1 {
                // 第一次：思考型，只有 reasoning 无 content
                return (Self.okResponse, Data(
                    #"{"choices":[{"message":{"reasoning_content":"thinking","content":null}}]}"#.utf8))
            }
            secondBody = body
            return (Self.okResponse, Data(#"{"choices":[{"message":{"content":"Hello"}}]}"#.utf8))
        }
        let client = makeClient(isThinking: true)
        let text = try await client.complete(prompt: "hi", maxTokens: 600, temperature: 0.7)

        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(callCount, 2, "thinkingOnly 应自动重试一次")
        let disabledThinking = secondBody["thinking"] as? [String: String]
        XCTAssertEqual(disabledThinking?["type"], "disabled", "降级请求显式关闭思考（删参数不生效）")
        XCTAssertNil(secondBody["thinking_budget"])
        XCTAssertEqual(secondBody["temperature"] as? Double, 0.7, "降级请求恢复 temperature")
    }

    /// 思考型流式：reasoning 后正文空 → 自动重试一次（关闭思考）→ 流式返回正文。
    func testStreamRetriesWithoutThinkingOnThinkingOnly() async throws {
        var callCount = 0
        var secondBody: [String: Any] = [:]
        ProbeURLProtocol.handler = { request in
            callCount += 1
            let data = try XCTUnwrap(Self.bodyData(of: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if callCount == 1 {
                let sse = """
                data: {"choices":[{"delta":{"reasoning_content":"deep thinking"}}]}

                data: [DONE]

                """
                return (Self.okResponse, Data(sse.utf8))
            }
            secondBody = body
            let sse = """
            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"content":" world"}}]}

            data: [DONE]

            """
            return (Self.okResponse, Data(sse.utf8))
        }
        let client = makeClient(isThinking: true)
        let tokens = TokenBox()
        let text = try await client.stream(prompt: "hi", maxTokens: 600, temperature: 0.7) { token in
            tokens.values.append(token)
        }

        XCTAssertEqual(text, "Hello world")
        XCTAssertEqual(callCount, 2, "thinkingOnly 应自动重试一次")
        XCTAssertEqual(tokens.values, ["Hello", " world"])
        let disabledThinking = secondBody["thinking"] as? [String: String]
        XCTAssertEqual(disabledThinking?["type"], "disabled", "降级请求显式关闭思考（删参数不生效）")
        XCTAssertNil(secondBody["thinking_budget"])
        XCTAssertEqual(secondBody["temperature"] as? Double, 0.7)
    }

    /// 思考型流式：正文非空但被 max_tokens 截断（finish_reason=length，思考挤占正文空间）
    /// → 也触发降级重试（关闭思考），拿到完整正文。
    func testStreamThinkingTruncatedByLengthRetriesDisabled() async throws {
        var callCount = 0
        var secondBody: [String: Any] = [:]
        ProbeURLProtocol.handler = { request in
            callCount += 1
            let data = try XCTUnwrap(Self.bodyData(of: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if callCount == 1 {
                let sse = """
                data: {"choices":[{"delta":{"reasoning_content":"long thinking consumes budget"}}]}

                data: {"choices":[{"delta":{"content":"Short truncated body"}}]}

                data: {"choices":[{"delta":{},"finish_reason":"length"}]}

                data: [DONE]

                """
                return (Self.okResponse, Data(sse.utf8))
            }
            secondBody = body
            let sse = """
            data: {"choices":[{"delta":{"content":"Full complete article body"}}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

            """
            return (Self.okResponse, Data(sse.utf8))
        }
        let client = makeClient(isThinking: true)
        let text = try await client.stream(prompt: "hi", maxTokens: 600, temperature: 0.7) { _ in }

        XCTAssertEqual(text, "Full complete article body")
        XCTAssertEqual(callCount, 2, "被 length 截断也应降级重试")
        let disabledThinking = secondBody["thinking"] as? [String: String]
        XCTAssertEqual(disabledThinking?["type"], "disabled")
    }

    /// 思考型 complete：正文非空但 finish_reason=length（思考挤占）→ 降级重试拿完整正文。
    func testCompleteThinkingTruncatedByLengthRetriesDisabled() async throws {
        var callCount = 0
        var secondBody: [String: Any] = [:]
        ProbeURLProtocol.handler = { request in
            callCount += 1
            let data = try XCTUnwrap(Self.bodyData(of: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if callCount == 1 {
                return (Self.okResponse, Data(
                    #"{"choices":[{"message":{"reasoning_content":"thinking","content":"Cut off here"},"finish_reason":"length"}]}"#.utf8))
            }
            secondBody = body
            return (Self.okResponse, Data(
                #"{"choices":[{"message":{"content":"Complete answer"},"finish_reason":"stop"}]}"#.utf8))
        }
        let client = makeClient(isThinking: true)
        let text = try await client.complete(prompt: "hi", maxTokens: 600, temperature: 0.7)

        XCTAssertEqual(text, "Complete answer")
        XCTAssertEqual(callCount, 2)
        let disabledThinking = secondBody["thinking"] as? [String: String]
        XCTAssertEqual(disabledThinking?["type"], "disabled")
    }

    /// 非思考型流式：无任何 delta → emptyResponse（保持原语义）。
    func testStreamThrowsEmptyResponseForPlainEmpty() async throws {
        ProbeURLProtocol.handler = { _ in
            (Self.okResponse, Data("data: [DONE]\n".utf8))
        }
        let client = makeClient(isThinking: false)
        do {
            _ = try await client.stream(prompt: "hi", maxTokens: 100, temperature: 0.3) { _ in }
            XCTFail("应抛错")
        } catch LLMClientError.emptyResponse {
            // 期望
        } catch {
            XCTFail("应为 emptyResponse，实际 \(error)")
        }
    }

    /// 普通型配置但模型默认思考（如 DeepSeek 未显式关闭）：收到 reasoning 无正文 → 也自动降级关闭思考。
    func testPlainClientRetriesDisabledThinkingWhenReasoningOnly() async throws {
        var callCount = 0
        var secondBody: [String: Any] = [:]
        ProbeURLProtocol.handler = { request in
            callCount += 1
            let data = try XCTUnwrap(Self.bodyData(of: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if callCount == 1 {
                XCTAssertNil(body["thinking"], "首次为普通请求不带 thinking 参数")
                return (Self.okResponse, Data(
                    #"{"choices":[{"message":{"reasoning_content":"default thinking","content":null}}]}"#.utf8))
            }
            secondBody = body
            return (Self.okResponse, Data(#"{"choices":[{"message":{"content":"Hello"}}]}"#.utf8))
        }
        let client = makeClient(isThinking: false)
        let text = try await client.complete(prompt: "hi", maxTokens: 600, temperature: 0.7)

        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(callCount, 2)
        let disabledThinking = secondBody["thinking"] as? [String: String]
        XCTAssertEqual(disabledThinking?["type"], "disabled", "普通型也降级为显式关闭思考")
    }

    // MARK: - 探测

    /// 探测：响应含 reasoning_content → 思考型。
    func testProbeDetectsThinkingModel() async throws {
        ProbeURLProtocol.handler = { _ in
            let body = #"{"choices":[{"message":{"reasoning_content":"hmm","content":"OK"}}]}"#
            return (Self.okResponse, Data(body.utf8))
        }
        let client = makeClient(isThinking: false)
        let result = await client.probe()
        XCTAssertTrue(result.reachable)
        XCTAssertEqual(result.isThinking, true)
    }

    /// 探测：响应无 reasoning_content → 普通型。
    func testProbeDetectsPlainModel() async throws {
        ProbeURLProtocol.handler = { _ in
            let body = #"{"choices":[{"message":{"content":"OK"}}]}"#
            return (Self.okResponse, Data(body.utf8))
        }
        let client = makeClient(isThinking: false)
        let result = await client.probe()
        XCTAssertTrue(result.reachable)
        XCTAssertEqual(result.isThinking, false)
    }

    /// 探测：连接失败 → reachable=false（保留原判定不打断）。
    func testProbeUnreachable() async {
        let client = OpenAICompatibleClient(
            baseURL: "http://127.0.0.1:1/v1", apiKey: nil, model: "qwen2.5")
        let result = await client.probe()
        XCTAssertFalse(result.reachable)
        XCTAssertNil(result.isThinking)
    }
}

// MARK: - URLSession stub

private final class ProbeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// @Sendable 闭包内安全累积 token（引用容器）。
private final class TokenBox: @unchecked Sendable {
    var values: [String] = []
}
