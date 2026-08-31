import Foundation

/// 上下文压缩工具：LLM 调用前估算 prompt token，超窗预算时对长输入做 head-tail 截断，
/// 防止 prompt 超过模型上下文窗口（本地小模型 n_ctx 常只有 2048）导致解码失败/输出被挤没。
/// @ai: 只读纯函数；供 LocalLLMGenerator 的正文/自查长 prompt 调用前压缩；短输入原样返回。
enum ContextCompressor {

    /// 粗略 token 估算：英文约 3-4 字符/token，取字符数/3（偏保守，宁可多省）。
    static func estimateTokens(_ text: String) -> Int {
        max(1, (text.utf16.count + 2) / 3)
    }

    /// 压缩到预算 token 数：保留头部与尾部、中间省略（指令/规则多在头尾，正文/文章多在中部）。
    /// 预算 ≤0 或未超窗 → 原样返回。
    static func truncate(_ text: String, toBudget budget: Int) -> String {
        guard budget > 0, estimateTokens(text) > budget else { return text }
        // 预算可容纳的字符数 ≈ budget × 3；头 60% + 尾 40%
        let capChars = max(64, budget * 3)
        let chars = Array(text)
        let head = String(chars.prefix(capChars * 3 / 5))
        let tail = String(chars.suffix(capChars * 2 / 5))
        return head + "\n\n[...上下文过长，中间已省略...]\n\n" + tail
    }
}
