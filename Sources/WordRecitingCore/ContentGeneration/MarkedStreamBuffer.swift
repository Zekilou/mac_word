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

/// 实时剥离前导垃圾行（大纲/计划回显、任务元句、前导空行）：
/// 普通正文开头立即放行；可疑开头（bullet/数字/大纲关键词/元句前缀）扣留到整行再判定后丢弃。
/// @ai: 与最终提取（extractMarkedBody 内 stripLeadingJunk）共用判定，保证实时展示 = 最终正文。
struct LeadingLineGuard {
    private var pending = ""
    private var started = false

    /// 追加一块流（已由 MarkedStreamBuffer 剥离标记），返回可放行的文本。
    mutating func append(_ chunk: String) -> String {
        if started { return chunk }
        pending += chunk
        var output = ""
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending = String(pending[pending.index(after: nl)...])
            if AgenticPrompts.isJunkLeadingLine(line) {
                continue
            }
            started = true
            output += line + "\n" + pending
            pending = ""
            break
        }
        if !started && !pending.isEmpty && !AgenticPrompts.startsLikeJunk(pending) {
            started = true
            output += pending
            pending = ""
        }
        return output
    }

    /// 流结束：剩余缓冲放行（最终正文由 extractMarkedBody 兜底剥离）。
    mutating func finalize() -> String {
        let out = pending
        pending = ""
        return out
    }
}

/// 实时守卫的引用包装：@Sendable onToken 回调内需可变捕获。
final class LeadingLineGuardBox: @unchecked Sendable {
    var guardValue = LeadingLineGuard()
}

/// 从流中提取模型的自我阶段标记行（"THINKING: <text>" / "[THINKING] <text>"）：
/// 内容路由到思考日志，行本身从正文剥离。行可跨 token 切碎，按行缓冲。
/// @ai: 模型自报"现在在干嘛"，与编排阶段（策略/逐词等）互补；解析失败不致命。
struct ThinkingLineExtractor {
    private var pending = ""

    /// 追加一块流，返回 (正文可见文本, 提取到的思考标记列表)。
    mutating func append(_ chunk: String) -> (visible: String, thoughts: [String]) {
        pending += chunk
        var visible = ""
        var thoughts: [String] = []
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending = String(pending[pending.index(after: nl)...])
            if let t = Self.thought(from: line) {
                thoughts.append(t)
            } else {
                visible += line + "\n"
            }
        }
        // 尾部（尚无换行）：不可能成为思考标记前缀时立即放行，防实时显示被卡住、防内容滞留丢失
        if !pending.isEmpty, !Self.isThinkingPrefix(pending) {
            visible += pending
            pending = ""
        }
        return (visible, thoughts)
    }

    /// 流结束：剩余尾部按同一规则处理。
    mutating func finalize() -> (visible: String, thoughts: [String]) {
        let tail = pending
        pending = ""
        if let t = Self.thought(from: tail) { return ("", [t]) }
        return (tail, [])
    }

    /// 从一行提取思考内容；非思考行返回 nil。
    static func thought(from line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        if lower.hasPrefix("thinking:") {
            let c = String(t.dropFirst("thinking:".count)).trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? nil : c
        }
        if lower.hasPrefix("[thinking]") {
            let c = String(t.dropFirst("[thinking]".count)).trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? nil : c
        }
        return nil
    }

    /// 判断累积文本是否可能是思考标记（"THINKING:" / "[THINKING]"）的前缀（大小写不敏感）。
    static func isThinkingPrefix(_ s: String) -> Bool {
        let lower = s.lowercased()
        return "thinking:".hasPrefix(lower) || "[thinking]".hasPrefix(lower)
    }
}

/// 思考行提取器的引用包装（含自增序号，供思考日志条目 id）。
final class ThinkingLineExtractorBox: @unchecked Sendable {
    var extractor = ThinkingLineExtractor()
    var seq = 0
}
