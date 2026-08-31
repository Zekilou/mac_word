import Foundation

/// LLM 客户端统一协议：所有后端（进程内 llama.cpp / OpenAI 兼容 / 本地 Ollama）
/// 实现同一接口，供 LocalLLMGenerator 无差别调用。
/// @ai: 协议保持最小面——只承诺"给一段 prompt，返回一段文本"。
///      联网策略：进程内实现零网络；远端实现仅按用户显式配置启用。
protocol LLMClient: Sendable {
    /// 客户端唯一标识（"llama-cpp" / "openai" / "ollama"）。
    static var identifier: String { get }
    /// 发送 completion 请求，返回模型生成的文本。
    /// - Parameters:
    ///   - prompt: 完整提示词（含系统要求 + 任务正文）
    ///   - maxTokens: 输出最大 token 数
    ///   - temperature: 采样温度（0.0 严格 → 1.5 发散）
    func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String
    /// 流式生成：逐段回调 onToken，返回完整文本（用于实时进度展示）。
    /// @ai: 协议要求 + 默认实现退化为一次性回调完整文本，非流式后端/测试 mock 无需改动。
    func stream(
        prompt: String, maxTokens: Int, temperature: Double,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

// MARK: - 默认流式实现

extension LLMClient {
    func stream(
        prompt: String, maxTokens: Int, temperature: Double,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let text = try await complete(prompt: prompt, maxTokens: maxTokens, temperature: temperature)
        if !text.isEmpty { onToken(text) }
        return text
    }
}

// MARK: - 共享提示词

/// 生成文章的共享 system 提示词（远端与进程内后端保持一致）。
enum LLMSystemPrompt {
    /// 要求模型只输出文章正文，便于 span 扫描。
    static let articleOnly = """
    You are a helpful English writing assistant for vocabulary learning.
    Output ONLY the requested article text, with no preamble, no explanation, and no markdown.
    """
}

// MARK: - 统一错误

/// LLM 客户端错误。
enum LLMClientError: LocalizedError, Sendable {
    case emptyResponse
    /// 思考型模型只吐了思考过程、未输出正文（max_tokens 被思考挤占或模型放弃作答）。
    case thinkingOnly
    case httpStatus(Int, String)
    case invalidURL
    case connection(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "LLM 返回了空响应"
        case .thinkingOnly:
            return "模型只进行了思考、未生成正文（思考预算可能被耗尽），请重试。"
        case .httpStatus(let code, let body):
            return "LLM 服务返回 HTTP \(code)：\(body.prefix(200))"
        case .invalidURL:
            return "LLM 服务地址无效"
        case .connection(let detail):
            return "无法连接 LLM 服务：\(detail)"
        case .decoding(let msg):
            return "无法解析 LLM 响应：\(msg)"
        }
    }
}
