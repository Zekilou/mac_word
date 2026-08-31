import Foundation

/// 远端词向量提供者（OpenAI 兼容 `/embeddings` 端点）。
/// @ai: 对接 Ollama（nomic-embed-text 等）/ OpenAI（text-embedding-3-small）/ 任意兼容网关；
///      与生成 LLM 同一服务地址与 Key（设置页「词向量来源」选远端时使用）。
///      查询失败返回 nil（不抛错）——上层走词库数据/LLM 伪向量兜底，不打断生成。
final class RemoteEmbeddingProvider: EmbeddingProvider {
    /// baseURL 形如 "https://api.openai.com/v1"（不含尾部 /embeddings）。
    private let baseURL: String
    private let apiKey: String?
    private let model: String
    private let session: URLSession
    /// 词 → 向量缓存（同一草稿内同词多次查只发一次请求；远端延迟高，必须缓存）。
    private let cache = CacheBox()

    init(baseURL: String, apiKey: String?, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func vector(for word: String) async -> [Float]? {
        let key = word.lowercased()
        if let cached = cache.get(key) { return cached }
        guard let data = await request(word: key) else {
            return nil
        }
        guard let vec = Self.parseEmbedding(data) else { return nil }
        cache.put(key, vec)
        return vec
    }

    // MARK: - 请求

    /// {baseURL}/embeddings；baseURL 末尾斜杠兼容。
    private var endpointURL: URL? {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: trimmed + "/embeddings")
    }

    private func request(word: String) async -> Data? {
        guard let url = endpointURL else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["model": model, "input": word]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - 解析

    /// 解析 `{"data":[{"embedding":[Float]}]}`；格式不符返回 nil。
    private static func parseEmbedding(_ data: Data) -> [Float]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]],
              let first = list.first,
              let raw = first["embedding"] as? [NSNumber] else { return nil }
        return raw.map { $0.floatValue }
    }
}

// MARK: - 缓存（@unchecked Sendable 容器）

/// 词 → 向量缓存（NSCache 线程安全，@unchecked Sendable 包装）。
private final class CacheBox: @unchecked Sendable {
    private let cache = NSCache<NSString, NSArray>()

    init() {
        cache.countLimit = 2000
    }

    func get(_ key: String) -> [Float]? {
        cache.object(forKey: key as NSString) as? [Float]
    }

    func put(_ key: String, _ value: [Float]) {
        cache.setObject(value as NSArray, forKey: key as NSString)
    }
}
