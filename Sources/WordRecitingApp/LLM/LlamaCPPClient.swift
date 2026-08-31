import Foundation
import LlamaSwift

/// 进程内 llama.cpp 客户端（LlamaSwift 提供的 llama.cpp C API）。
/// @ai: LLMClient 协议实现——加载 GGUF 到进程内，零网络推理；采样固定 greedy（忽略 temperature）。
///      重量操作放 Task.detached 后台执行，避免卡主线程。
struct LlamaCPPClient: LLMClient {
    static let identifier = "llama-cpp"

    /// GGUF 模型文件路径（由设置页「进程内模型」选择）。
    let modelPath: String
    /// 上下文窗口（token 数）。
    let nCtx: UInt32
    /// 解码线程数。
    let nThreads: Int32

    init(modelPath: String, nCtx: UInt32 = 2048, nThreads: Int32 = 4) {
        self.modelPath = modelPath
        self.nCtx = nCtx
        self.nThreads = nThreads
    }

    func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        try await stream(prompt: prompt, maxTokens: maxTokens, temperature: temperature) { _ in }
    }

    func stream(
        prompt: String, maxTokens: Int, temperature: Double,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let path = modelPath
        let ctx = nCtx
        let threads = nThreads
        return try await Task.detached(priority: .userInitiated) {
            try LlamaEngine.generate(
                modelPath: path, prompt: prompt,
                maxTokens: maxTokens, temperature: temperature,
                nCtx: ctx, nThreads: threads, onToken: onToken)
        }.value
    }
}

/// 进程内推理引擎：封装 llama.cpp C API（llama-model → context → tokenize → decode → sample）。
/// @ai: 每次调用加载/释放模型（MVP 简单可靠）；模型上下文不跨线程共享。
enum LlamaEngine {

    /// 进程内推理错误。
    enum InferenceError: LocalizedError, Sendable {
        case modelLoadFailed
        case contextCreateFailed
        case tokenizeFailed
        case decodeFailed(Int32)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed: return "无法加载模型文件（可能不是有效的 GGUF，或模型与引擎不兼容）"
            case .contextCreateFailed: return "无法创建推理上下文（内存不足或上下文过大）"
            case .tokenizeFailed: return "提示词分词失败"
            case .decodeFailed(let code): return "推理解码失败（代码 \(code)）"
            case .emptyOutput: return "模型未生成任何内容"
            }
        }
    }

    static func generate(
        modelPath: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        nCtx: UInt32,
        nThreads: Int32,
        onToken: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
        // 模型经共享缓存常驻复用（backend 全局初始化一次；同路径模型不重复加载，
        // 切换路径/空闲超时才释放——避免每次生成把 GGUF 反复搬进搬出内存）。
        let (model, vocab) = try LlamaModelCache.shared.session(for: modelPath)

        // 2. 创建上下文（每任务各自建，KV 缓存独立；模型权重共享）
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = nCtx
        ctxParams.n_batch = 512
        let batchSize = Int32(512)
        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw InferenceError.contextCreateFailed
        }
        defer { llama_free(ctx) }
        llama_set_n_threads(ctx, nThreads, max(2, nThreads * 2))

        // 3. 采样链：重复惩罚（抑制小模型"复读"循环）→ 温度 + 分布采样（随机），
        //    或 temperature <= 0 时退化为 greedy。
        //    @ai: 修复"多次生成完全相同"：此前固定 greedy（temperature 被忽略）→
        //    相同输入永远相同输出。现在温度 > 0 时走 temp + dist（随机种子），输出有差异。
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else {
            throw InferenceError.contextCreateFailed
        }
        defer { llama_sampler_free(chain) }
        let vocabCount = llama_vocab_n_tokens(vocab)
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            vocabCount, 128, 1.2, 0.0, 0.0))
        if temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(temperature)))
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(0.05, 1))
            // LLAMA_DEFAULT_SEED（0xFFFFFFFF）= 每次随机种子，输出有差异
            llama_sampler_chain_add(chain, llama_sampler_init_dist(0xFFFF_FFFF))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }

        // 4. 提示词 → tokens
        //    优先用模型自带 chat template 包裹（系统提示 + 用户提示），
        //    避免 chat 模型把裸提示词当"续写文本"回显提示词而不是作答。
        let chatPrompt: String?
        if let template = Self.chatTemplate(for: model) {
            chatPrompt = Self.applyChatTemplate(
                template, system: LLMSystemPrompt.articleOnly, user: prompt)
        } else {
            chatPrompt = nil
        }
        let promptText = chatPrompt ?? "\(LLMSystemPrompt.articleOnly)\n\n\(prompt)"
        var promptTokens = [llama_token](repeating: 0, count: 4096)
        let tokenCount = promptText.withCString { cs in
            llama_tokenize(vocab, cs, Int32(promptText.utf8.count),
                           &promptTokens, Int32(promptTokens.count),
                           chatPrompt == nil, chatPrompt != nil)
        }
        guard tokenCount > 0 else { throw InferenceError.tokenizeFailed }
        promptTokens = Array(promptTokens[0..<Int(tokenCount)])

        // 5. 解码提示词批次（超过 n_batch 时分片，避免 llama.cpp 对超大 batch 直接 abort）
        //    @ai: 自查 pass 会把整篇文章嵌进提示词（>512 token），必须分片解码。
        var promptOffset = 0
        while promptOffset < promptTokens.count {
            var chunk = Array(promptTokens[promptOffset..<min(promptOffset + Int(batchSize), promptTokens.count)])
            let batch = llama_batch_get_one(&chunk, Int32(chunk.count))
            guard llama_decode(ctx, batch) >= 0 else {
                throw InferenceError.decodeFailed(-1)
            }
            promptOffset += chunk.count
        }

        // 6. 逐 token 生成（每 token 回调一次，供实时进度展示）
        var output = ""
        var leadingEogSkips = 0
        for _ in 0..<maxTokens {
            let token = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, token) {
                // 开头就 EOG（模型偶发未开始输出）→ 跳过重采；已有输出时 EOG = 正常结束
                if output.isEmpty && leadingEogSkips < 3 {
                    leadingEogSkips += 1
                    continue
                }
                break
            }
            let piece = piece(for: token, vocab: vocab)
            output += piece
            onToken?(piece)
            var nextToken = [token]
            let nextBatch = llama_batch_get_one(&nextToken, 1)
            if llama_decode(ctx, nextBatch) < 0 { break }
        }
        guard !output.isEmpty else { throw InferenceError.emptyOutput }
        return output
    }

    /// token → 文本（UTF-8）。
    private static func piece(for token: llama_token, vocab: OpaquePointer) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        let len = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        guard len > 0 else { return "" }
        let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Chat template

    /// 读取 GGUF 元数据中的 `tokenizer.chat_template`（如 qwen 的 `<|im_start|>` 模板）。
    private static func chatTemplate(for model: OpaquePointer) -> String? {
        var buf = [CChar](repeating: 0, count: 8192)
        var len = llama_model_meta_val_str(model, "tokenizer.chat_template", &buf, buf.count)
        if len >= buf.count {
            buf = [CChar](repeating: 0, count: Int(len) + 1)
            len = llama_model_meta_val_str(model, "tokenizer.chat_template", &buf, buf.count)
        }
        guard len > 0 else { return nil }
        return string(from: buf, length: Int(len))
    }

    /// 用模型自带 chat template 组装「system + user」消息并追加 assistant 引导标记。
    /// 模板不受支持时返回 nil（调用方回退到裸提示词）。
    private static func applyChatTemplate(_ tmpl: String, system: String, user: String) -> String? {
        tmpl.withCString { tmplC in
            "system".withCString { sysRoleC in
                system.withCString { sysC in
                    "user".withCString { usrRoleC in
                        user.withCString { usrC in
                            var messages = [
                                llama_chat_message(role: sysRoleC, content: sysC),
                                llama_chat_message(role: usrRoleC, content: usrC),
                            ]
                            var buf = [CChar](repeating: 0, count: 4096)
                            let needed = llama_chat_apply_template(
                                tmplC, &messages, 2, true, &buf, Int32(buf.count))
                            guard needed > 0 else { return nil }
                            if Int(needed) > buf.count {
                                buf = [CChar](repeating: 0, count: Int(needed) + 1)
                                guard llama_chat_apply_template(
                                    tmplC, &messages, 2, true, &buf, Int32(buf.count)) > 0 else {
                                    return nil
                                }
                            }
                            return string(from: buf, length: Int(needed))
                        }
                    }
                }
            }
        }
    }

    /// C 缓冲区 + 长度 → String（截掉可能含的结尾 null）。
    private static func string(from buf: [CChar], length: Int) -> String {
        let bytes = buf.prefix(length).prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
