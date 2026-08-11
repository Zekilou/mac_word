import Foundation

/// Agentic 逐词融入的评估与循环（extension）。
/// @ai: 每个词独立闭环：专注改写 → 评估（存在性/语义/重复）→ 反馈重试 → 换锚点 → 跳过。
extension LocalLLMGenerator {

    /// 一个词融入的最终产物。
    enum EmbedResult: Sendable {
        case success(String)
        case skipped(SkippedWord)
    }

    /// 评估器与循环配置。
    struct EmbedConfig: Sendable {
        var verification: EmbeddingVerification = .standard
        var maxAttempts: Int = 3
        var maxAnchorSwitches: Int = 1
    }

    /// 一次尝试的评估结论。
    enum Verdict: Sendable {
        case pass
        case fail([String])
    }

    /// 对一个词执行专注改写循环：K 次尝试 → 换锚点（M 次）→ 跳过。
    func embedWord(
        word: String, anchorIndex: Int, associations: String,
        sentences: [String], usedIndexes: Set<Int>, config: EmbedConfig
    ) async throws -> EmbedResult {
        onProgress?(.thought(GenThought(
            id: "embed-\(word)", kind: .embedding,
            message: "融入 \(word)（锚点句#\(anchorIndex)）", detail: nil, status: .running)))
        let history = AttemptHistory()
        var anchor = anchorIndex
        var anchorSwitches = 0
        while true {
            try Task.checkCancellation()
            guard sentences.indices.contains(anchor) else {
                onProgress?(.thought(GenThought(
                    id: "embed-\(word)", kind: .embedding,
                    message: "融入 \(word)：锚点句缺失，跳过", detail: nil, status: .failed)))
                return .skipped(SkippedWord(word: word, reason: "草稿为空或锚点句缺失"))
            }
            let sentence = sentences[anchor]
            var attempts = 0
            var lastFeedback: [String]?
            while attempts < config.maxAttempts {
                try Task.checkCancellation()
                let prompt = AgenticPrompts.focusedRewritePrompt(
                    sentence: sentence, word: word,
                    associations: associations, feedback: lastFeedback)
                let raw = try? await client.complete(
                    prompt: prompt, maxTokens: 120, temperature: 0.5)
                let rewritten = (raw.map { Self.cleanArticle($0) } ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                attempts += 1
                if rewritten.isEmpty {
                    lastFeedback = ["空输出"]
                    continue
                }
                switch await evaluateRewritten(
                    original: sentence, rewritten: rewritten, word: word,
                    history: history, config: config) {
                case .pass:
                    onProgress?(.thought(GenThought(
                        id: "embed-\(word)", kind: .embedding,
                        message: "融入 \(word)：改写成功（锚点句#\(anchor)）",
                        detail: nil, status: .done)))
                    return .success(rewritten)
                case .fail(let reasons):
                    lastFeedback = reasons
                }
            }
            if anchorSwitches < config.maxAnchorSwitches,
               let next = nextFreeAnchor(after: anchor, in: sentences, used: usedIndexes) {
                anchor = next
                anchorSwitches += 1
                continue
            }
            let reason = "\(config.maxAttempts) 次尝试后仍无法自然融入"
            onProgress?(.thought(GenThought(
                id: "embed-\(word)", kind: .embedding,
                message: "融入 \(word)：失败，跳过", detail: reason, status: .failed)))
            return .skipped(SkippedWord(word: word, reason: reason))
        }
    }

    /// 评估一句改写：存在性（规则）+ 语义保真（LLM，按强度）+ 重复检测（规则）。
    func evaluateRewritten(
        original: String, rewritten: String, word: String,
        history: AttemptHistory, config: EmbedConfig
    ) async -> Verdict {
        var reasons: [String] = []
        let contains = Self.containsWord(rewritten, word: word)
        if !contains { reasons.append("目标词缺失") }
        let duplicate = history.isDuplicate(rewritten)
        if duplicate { reasons.append("重复输出") }
        history.append(rewritten)

        let shouldVerify: Bool
        switch config.verification {
        case .light: shouldVerify = false
        case .standard: shouldVerify = !history.semanticChecked
        case .strict: shouldVerify = true
        }
        if contains && !duplicate && shouldVerify {
            history.markSemanticChecked()
            let raw = try? await client.complete(
                prompt: AgenticPrompts.verificationPrompt(original: original, rewritten: rewritten),
                maxTokens: 60, temperature: 0)
            if !AgenticPrompts.parseVerification(raw) {
                reasons.append("意思改变")
            }
        }
        return reasons.isEmpty ? .pass : .fail(reasons)
    }

    /// 目标词是否出现在句中（WordNormalizer 归一化匹配，容忍屈折变化）。
    static func containsWord(_ sentence: String, word: String) -> Bool {
        let target = WordNormalizer.normalize(word)
        guard !target.isEmpty else {
            return sentence.lowercased().contains(word.lowercased())
        }
        let tokens = sentence.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .map { WordNormalizer.normalize(String($0)) }
        return tokens.contains(target)
    }

    /// 锚点后第一个未被占用的句索引（循环找，找不到返回 nil）。
    private func nextFreeAnchor(after idx: Int, in sentences: [String], used: Set<Int>) -> Int? {
        guard !sentences.isEmpty else { return nil }
        for offset in 1...sentences.count {
            let candidate = (idx + offset) % sentences.count
            if !used.contains(candidate) && !sentences[candidate].isEmpty {
                return candidate
            }
        }
        return nil
    }
}

/// 循环内历史：已尝试句子（重复检测）+ 语义是否已判定。
final class AttemptHistory: @unchecked Sendable {
    private(set) var attempts: [String] = []
    private(set) var semanticChecked = false
    func append(_ s: String) { attempts.append(s) }
    func markSemanticChecked() { semanticChecked = true }
    /// 与历史任一尝试归一化相似度 > 0.9 视为重复。
    func isDuplicate(_ s: String) -> Bool {
        attempts.contains { Self.similarity($0, s) > 0.9 }
    }
    /// 归一化文本相似度（小写去空白 + 字符级 Levenshtein）。
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalized(a), y = normalized(b)
        if x == y { return 1.0 }
        guard !x.isEmpty, !y.isEmpty else { return 0.0 }
        let dist = levenshtein(Array(x), Array(y))
        return 1.0 - Double(dist) / Double(max(x.count, y.count))
    }
    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let tmp = dp[j]
                dp[j] = min(dp[j] + 1, dp[j - 1] + 1,
                            prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return dp[b.count]
    }
}
