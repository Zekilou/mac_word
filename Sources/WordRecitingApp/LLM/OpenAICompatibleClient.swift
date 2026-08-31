import Foundation

/// OpenAI 兼容 Chat Completions 客户端。
/// 同一实现可对接：
/// - OpenAI 官方 API（https://api.openai.com/v1）
/// - 本地 Ollama（http://localhost:11434/v1，OpenAI 兼容端点）
/// - 任何 OpenAI 兼容网关（vLLM / LM Studio / DeepSeek 等）
/// @ai: 纯本地优先——apiKey 为空 + baseURL 指向 localhost 时完全离线。
///      思考型模型（isThinking=true）：请求体带 `thinking` 开关 + `thinking_budget` 独立预算，
///      流式先吐 reasoning_content（content=null）再吐 content，思考段不产生正文 token。
struct OpenAICompatibleClient: LLMClient {
    static let identifier = "openai-compatible"

    /// baseURL 形如 "https://api.openai.com/v1"（不含尾部 /chat/completions）。
    let baseURL: String
    /// 可选 API Key；本地服务可为空。
    let apiKey: String?
    /// 模型名（如 "gpt-4o-mini" / "qwen2.5" / "deepseek-v4-flash"）。
    let model: String
    /// 是否思考型模型（探测后由调用方传入）。思考型默认开启思考，不传 temperature。
    var isThinking: Bool = false
    /// 思考 token 独立预算（思考型有效；DeepSeek `thinking_budget` / Claude `budget_tokens` 同语义）。
    var thinkingBudget: Int = ThinkingBudget.default
    /// 普通模型静默超时：连续无内容到达的秒数上限（按模型输出速率自适应截止）。
    var idleTimeout: TimeInterval = 60
    /// 思考型模型静默超时：思考段可能长时间无 content token，允许更久。
    var thinkingIdleTimeout: TimeInterval = 180
    /// 网络会话（默认共享；测试注入 StubURLProtocol）。
    var session: URLSession = .shared

    init(
        baseURL: String, apiKey: String?, model: String,
        isThinking: Bool = false, thinkingBudget: Int = ThinkingBudget.default,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.isThinking = isThinking
        self.thinkingBudget = thinkingBudget
        self.session = session
    }

    /// 有效输出上限：思考型模型把思考预算与正文分开计，正文空间 = 调用方给的 maxTokens。
    func effectiveMaxTokens(_ maxTokens: Int) -> Int {
        maxTokens + (isThinking ? thinkingBudget : 0)
    }

    func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        let body = try makeBody(prompt: prompt, maxTokens: effectiveMaxTokens(maxTokens),
                                temperature: temperature, stream: false)
        do {
            let data = try await post(body: body)
            return try Self.parseChatCompletion(data)
        } catch LLMClientError.thinkingOnly {
            // 收到 reasoning 但正文空（思考挤占预算/模型默认思考）→ 降级重试一次：显式关闭思考
            do {
                let data = try await post(body: Self.fallbackBody(from: body, temperature: temperature))
                return try Self.parseChatCompletion(data)
            } catch LLMClientError.thinkingOnly {
                // 降级后仍无正文 → 归一为可理解的空响应错误
                throw LLMClientError.emptyResponse
            }
        }
    }

    /// 流式生成：SSE 逐 delta 回调 onToken（打字机效果），返回完整文本。
    /// 思考型模型：跳过 reasoning_content 段（不回调 onToken），只收 content 正文；
    ///              思考后正文空（thinkingOnly）→ 自动降级重试一次（关闭思考）。
    /// @ai: 静默超时（截止条件自适应）——连续 idleTimeout 秒无任何字节到达即抛错停止，
    ///      思考型模型思考段可长时间无 content，用更长的 thinkingIdleTimeout。
    func stream(
        prompt: String, maxTokens: Int, temperature: Double,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let body = try makeBody(prompt: prompt, maxTokens: effectiveMaxTokens(maxTokens),
                                temperature: temperature, stream: true)
        do {
            return try await streamOnce(body: body, temperature: temperature,
                                        onToken: onToken, isThinkingRequest: isThinking)
        } catch LLMClientError.thinkingOnly {
            // 收到 reasoning 但正文空（思考挤占预算/模型默认思考）→ 降级重试一次：显式关闭思考
            let fallback = Self.fallbackBody(from: body, temperature: temperature)
            do {
                return try await streamOnce(body: fallback, temperature: temperature,
                                            onToken: onToken, isThinkingRequest: false)
            } catch LLMClientError.thinkingOnly {
                // 降级后仍无正文 → 归一为可理解的空响应错误
                throw LLMClientError.emptyResponse
            }
        }
    }

    /// 单次流式请求（思考请求与降级重试共用）。
    /// @ai: isThinkingRequest=true 且只收到 reasoning 无正文 → thinkingOnly（触发上层降级）；
    ///      降级请求（false）即便收到 reasoning 数据也按 emptyResponse 处理（普通请求空响应即空）。
    private func streamOnce(
        body: [String: Any], temperature: Double,
        onToken: @escaping @Sendable (String) -> Void,
        isThinkingRequest: Bool
    ) async throws -> String {
        let url = try makeURL()
        let request = makeRequest(url: url, body: body)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw LLMClientError.connection(connectionHint(underlying: error))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMClientError.httpStatus(http.statusCode, "streaming request failed")
        }
        let idleLimit = isThinkingRequest ? thinkingIdleTimeout : idleTimeout
        let clock = IdleClockBox()
        return try await withThrowingTaskGroup(of: String.self) { group in
            // 主读取任务：逐行解析 SSE
            group.addTask {
                var accumulated = ""
                var sawReasoning = false
                var sawTruncation = false
                for try await line in bytes.lines {
                    clock.tick()
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let choice = choices.first else { continue }
                    // 输出被 token 上限截断（思考型下思考挤占正文空间）
                    if (choice["finish_reason"] as? String) == "length" {
                        sawTruncation = true
                    }
                    guard let delta = choice["delta"] as? [String: Any] else { continue }
                    // 思考段：delta.reasoning_content 非空（此时 content 通常为 null）→ 跳过
                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        sawReasoning = true
                        continue
                    }
                    guard let content = delta["content"] as? String, !content.isEmpty else { continue }
                    accumulated += content
                    onToken(content)
                }
                guard !accumulated.isEmpty else {
                    // 收到 reasoning 但正文空 → thinkingOnly（思考挤占正文，触发上层降级关闭思考）
                    // 其余空响应 → emptyResponse（真没输出）
                    throw sawReasoning ? LLMClientError.thinkingOnly : LLMClientError.emptyResponse
                }
                // 正文非空但被 max_tokens 硬截断（思考型思考耗尽预算）→ 也降级重试关闭思考
                if sawTruncation && isThinkingRequest {
                    throw LLMClientError.thinkingOnly
                }
                return accumulated
            }
            // 静默超时看门狗：连续 idleLimit 秒无字节 → 停止
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    if Date().timeIntervalSince(clock.last) > idleLimit {
                        throw LLMClientError.connection(
                            "生成超时：连续 \(Int(idleLimit)) 秒未收到内容，已停止。")
                    }
                }
                return ""
            }
            let result = try await group.next() ?? ""
            group.cancelAll()
            return result
        }
    }

    /// 降级请求体：显式关闭思考（DeepSeek 默认 thinking.enabled，删除参数不生效）+ 恢复 temperature。
    /// @ai: 思考模式不支持 temperature；关闭思考后仍可正常传温度采样。
    private static func fallbackBody(from body: [String: Any], temperature: Double) -> [String: Any] {
        var fallback = body
        fallback["thinking"] = ["type": "disabled"]
        fallback.removeValue(forKey: "thinking_budget")
        fallback["temperature"] = temperature
        return fallback
    }

    // MARK: - 模型类型探测

    /// 探测结果：联通性 + 是否思考型。
    struct ProbeResult: Sendable {
        var reachable: Bool
        /// true=思考型 / false=普通型 / nil=无法判定（网关不支持或探测失败）
        var isThinking: Bool?
        var message: String?
    }

    /// 联通性 + 模型类型探测（配置变更时由调用方触发）。
    /// 发最小请求，据 `reasoning_content` 是否出现判定思考型；网关不支持 thinking 参数时回退探测。
    func probe() async -> ProbeResult {
        let prompt = "Reply with exactly the word: OK"
        // 第一轮：带 thinking 参数（思考型 API 才接受）
        var body: [String: Any]
        do {
            body = try makeBody(prompt: prompt, maxTokens: 64, temperature: 0, stream: false)
        } catch {
            return ProbeResult(reachable: false, isThinking: nil, message: "\(error)")
        }
        // 带思考参数的请求
        var thinkingBody = body
        thinkingBody["thinking"] = ["type": "enabled"]
        if let data = try? await post(body: thinkingBody) {
            return Self.analyzeProbe(data)
        }
        // 回退：不带 thinking 参数（普通型网关/Ollama 不接受）
        if let data = try? await post(body: body) {
            return Self.analyzeProbe(data)
        }
        // 都失败 → 连接/鉴权问题
        do {
            _ = try await post(body: body)
            return ProbeResult(reachable: false, isThinking: nil, message: nil)
        } catch {
            return ProbeResult(reachable: false, isThinking: nil, message: "\(error)")
        }
    }

    /// 解析探测响应：含 reasoning_content → 思考型。
    private static func analyzeProbe(_ data: Data) -> ProbeResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return ProbeResult(reachable: true, isThinking: nil, message: nil)
        }
        let reasoning = (message["reasoning_content"] as? String) ?? ""
        let content = (message["content"] as? String) ?? ""
        if !reasoning.isEmpty {
            return ProbeResult(reachable: true, isThinking: true,
                               message: "思考型模型（探测到 reasoning_content）")
        }
        return ProbeResult(reachable: true, isThinking: false,
                           message: content.isEmpty ? "响应无正文" : "普通模型")
    }

    // MARK: - 请求构建与发送

    private func makeURL() throws -> URL {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw LLMClientError.invalidURL
        }
        return url
    }

    /// 构造请求体：思考型模型带 thinking 开关 + 独立预算，不传 temperature（思考模式不支持温度）。
    private func makeBody(prompt: String, maxTokens: Int, temperature: Double, stream: Bool) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt],
            ],
            "max_tokens": maxTokens,
            "stream": stream,
        ]
        if isThinking {
            body["thinking"] = ["type": "enabled"]
            body["thinking_budget"] = thinkingBudget
        } else {
            body["temperature"] = temperature
        }
        return body
    }

    private func makeRequest(url: URL, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 非流式 POST，返回响应体 Data。
    private func post(body: [String: Any]) async throws -> Data {
        let url = try makeURL()
        let request = makeRequest(url: url, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 网络层错误（连接拒绝 / 超时 / 无法解析主机名）→ 统一为 connection，给出可读提示
            throw LLMClientError.connection(connectionHint(underlying: error))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.httpStatus(http.statusCode, text)
        }
        return data
    }

    /// 生成连接失败的可读提示：区分 Ollama 未运行 / 地址错误 / 其他网络错误。
    private func connectionHint(underlying error: Error) -> String {
        let ns = error as NSError
        if baseURL.contains("localhost") || baseURL.contains("127.0.0.1") {
            return "无法访问 \(baseURL)。请确认 Ollama 已运行（终端执行 `ollama serve`）且已下载模型（`ollama pull <模型名>`）。"
        }
        return "\(baseURL) 连接失败（\(ns.localizedDescription)）。请检查服务地址与网络。"
    }

    // MARK: - 解析

    /// 从 Chat Completions 响应中提取第一条 content 文本。
    /// 思考型模型：message 含 reasoning_content 但 content 为空 → thinkingOnly；
    ///              content 非空但 finish_reason=length（思考挤占正文空间被截断）→ 也 thinkingOnly（触发降级）。
    private static func parseChatCompletion(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMClientError.decoding("非 JSON 对象")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMClientError.emptyResponse
        }
        let reasoning = (message["reasoning_content"] as? String) ?? ""
        let finishReason = (first["finish_reason"] as? String) ?? ""
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw reasoning.isEmpty ? LLMClientError.emptyResponse : LLMClientError.thinkingOnly
        }
        // 正文被 max_tokens 硬截断（思考型思考挤占正文空间）→ 降级重试关闭思考
        if finishReason == "length" && !reasoning.isEmpty {
            throw LLMClientError.thinkingOnly
        }
        return content
    }

    /// 系统提示词：要求输出纯文章正文，便于 span 扫描。
    private var systemPrompt: String { LLMSystemPrompt.articleOnly }
}

/// 流式静默超时时钟（@Sendable 任务间共享最后活动时刻）。
/// @ai: URLSession bytes.lines 迭代与看门狗任务并发访问，需引用容器。
final class IdleClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _last = Date()

    var last: Date {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    /// 记录一次数据到达。
    func tick() {
        lock.lock(); defer { lock.unlock() }
        _last = Date()
    }
}
