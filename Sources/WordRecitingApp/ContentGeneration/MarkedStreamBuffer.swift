import Foundation

/// 流式剥离输出约定标记：跳过开标记前的思考/前言；延迟尾部技术识别跨 chunk 的结束标记。
/// @ai: 生成器在 client.stream 的 onToken 里清洗后再转发 onProgress；VM 只收干净正文。
struct MarkedStreamBuffer {
    static let opening = "===ARTICLE_START==="
    static let closing = "===ARTICLE_END==="

    /// 完整原始流（最终提取与测试用）。
    private(set) var rawAll = ""
    /// 累积的干净正文（不含标记与前置思考）。
    private(set) var body = ""
    private var pending = ""
    private var started = false
    private var finished = false

    /// 追加一块流，返回可提交（展示）的干净文本。
    mutating func append(_ chunk: String) -> String {
        guard !finished else { return "" }
        rawAll += chunk
        pending += chunk
        if !started {
            if let r = pending.range(of: Self.opening) {
                started = true
                pending = String(pending[r.upperBound...])
            } else if !Self.opening.hasPrefix(pending) {
                started = true   // 模型未写开标记 → 全量展示（与 extractMarkedBody 回退一致）
            } else {
                return ""   // pending 仍是开标记前缀，继续等
            }
        }
        // 结束标记完整出现 → 截断提交并结束（后续丢弃）
        if let r = pending.range(of: Self.closing) {
            finished = true
            let before = String(pending[..<r.lowerBound])
            pending = ""
            if !before.isEmpty { body += before }
            return before
        }
        // 延迟尾部：与 closing 前缀匹配的最长后缀扣留，其余提交
        let hold = holdLength(pending)
        let commitCount = pending.count - hold
        guard commitCount > 0 else { return "" }
        let committed = String(pending.prefix(commitCount))
        body += committed
        pending = String(pending.dropFirst(commitCount))
        return committed
    }

    /// 流结束：剥离残留结束标记（含被截断的前缀），返回完整干净正文。
    mutating func finalize() -> String {
        if !finished {
            if pending.hasPrefix(Self.closing) || Self.closing.hasPrefix(pending) {
                pending = ""
            }
            body += pending
            pending = ""
        }
        return body
    }

    /// pending 中与 closing 前缀匹配的最长后缀长度（0..closing.count）。
    private func holdLength(_ s: String) -> Int {
        let n = min(s.count, Self.closing.count)
        guard n > 0 else { return 0 }
        var best = 0
        let chars = Array(s)
        for k in 1...n {
            if Self.closing.hasPrefix(String(chars.suffix(k))) { best = k }
        }
        return best
    }
}
