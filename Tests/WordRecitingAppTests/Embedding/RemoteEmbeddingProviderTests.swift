import XCTest
@testable import WordRecitingApp

/// RemoteEmbeddingProvider（OpenAI 兼容 /embeddings 端点）测试。
/// @ai: 全部 mock——StubURLProtocol 拦截网络，不触真实服务。
final class RemoteEmbeddingProviderTests: XCTestCase {

    /// 带 stub 会话的 provider（测试注入 EmbeddingURLProtocol）。
    private func makeProvider(
        model: String = "nomic-embed-text",
        apiKey: String? = "sk-test",
        baseURL: String = "https://api.test.local/v1"
    ) -> RemoteEmbeddingProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbeddingURLProtocol.self]
        return RemoteEmbeddingProvider(
            baseURL: baseURL, apiKey: apiKey, model: model,
            session: URLSession(configuration: config))
    }

    private static func ok(_ data: Data) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.test.local/v1/embeddings")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    /// 合法 embeddings 响应体。
    private static func embeddingJSON(_ vec: [Float]) -> Data {
        let body = [
            "data": [["embedding": vec]],
            "model": "nomic-embed-text",
        ] as [String: Any]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - 正常解析

    func testRemoteProviderReturnsVector() async {
        EmbeddingURLProtocol.handler = { _ in
            (Self.ok(Data()), Self.embeddingJSON([0.1, 0.2, 0.3]))
        }
        let provider = makeProvider()
        let vec = await provider.vector(for: "battle")
        XCTAssertEqual(vec, [0.1, 0.2, 0.3])
    }

    // MARK: - 请求构造

    func testRemoteProviderBuildsCorrectRequest() async throws {
        var capturedURL: URL?
        var capturedBody: [String: Any] = [:]
        var capturedAuth: String?
        EmbeddingURLProtocol.handler = { request in
            capturedURL = request.url
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let data = try XCTUnwrap(Self.bodyData(of: request))
            capturedBody = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (Self.ok(Data()), Self.embeddingJSON([0.1]))
        }
        let provider = makeProvider(apiKey: "sk-abc")
        _ = await provider.vector(for: "Battle")

        XCTAssertEqual(capturedURL?.path, "/v1/embeddings", "应打 /embeddings 端点")
        XCTAssertEqual(capturedBody["model"] as? String, "nomic-embed-text")
        XCTAssertEqual(capturedBody["input"] as? String, "battle", "统一小写发送（与缓存 key 一致）")
        XCTAssertEqual(capturedAuth, "Bearer sk-abc", "有 Key 时带 Authorization")
    }

    func testRemoteProviderSkipsAuthWhenNoKey() async throws {
        var capturedAuth: String?
        EmbeddingURLProtocol.handler = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            return (Self.ok(Data()), Self.embeddingJSON([0.1]))
        }
        let provider = makeProvider(apiKey: nil)
        _ = await provider.vector(for: "battle")
        XCTAssertNil(capturedAuth, "无 Key 不带头（本地 Ollama 场景）")
    }

    // MARK: - 失败兜底

    func testRemoteProviderNilOnHTTPError() async {
        EmbeddingURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "https://api.test.local/v1/embeddings")!,
                             statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let provider = makeProvider()
        let vec = await provider.vector(for: "battle")
        XCTAssertNil(vec, "HTTP 错误返回 nil，管线回退")
    }

    func testRemoteProviderNilOnBadJSON() async {
        EmbeddingURLProtocol.handler = { _ in
            (Self.ok(Data()), Data(#"{"data":[]}"#.utf8))
        }
        let provider = makeProvider()
        let vec = await provider.vector(for: "battle")
        XCTAssertNil(vec, "无 embedding 字段返回 nil")
    }

    func testRemoteProviderNilOnNetworkError() async {
        EmbeddingURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let provider = makeProvider()
        let vec = await provider.vector(for: "battle")
        XCTAssertNil(vec, "网络错误返回 nil")
    }

    // MARK: - 缓存

    func testRemoteProviderCachesQueries() async {
        var callCount = 0
        EmbeddingURLProtocol.handler = { _ in
            callCount += 1
            return (Self.ok(Data()), Self.embeddingJSON([0.1, 0.2]))
        }
        let provider = makeProvider()
        _ = await provider.vector(for: "battle")
        _ = await provider.vector(for: "battle")
        _ = await provider.vector(for: "battle")
        XCTAssertEqual(callCount, 1, "同词缓存，只发一次请求")
    }

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
}

/// URLProtocol stub：拦截全部请求，由 handler 返回（响应, 数据）或抛错。
private final class EmbeddingURLProtocol: URLProtocol {
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
