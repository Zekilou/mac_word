import Foundation

/// 一个目标词的锚点分配（联想内容 + 锚点句索引）。
struct AnchorAssignment: Sendable {
    let word: String
    let sentenceIndex: Int
    let associations: String
}

/// Agentic 逐词融入的提示词模板与宽容解析。
/// @ai: 模型输出固定结构（JSON/固定行），解析失败一律规则回退，不因 JSON 不稳中断。
enum AgenticPrompts {

    // MARK: - 联想 + 锚点选句（一次调用）

    static func anchorPrompt(sentences: [String], words: [String]) -> String {
        let numbered = sentences.enumerated()
            .map { "\($0.offset): \($0.element)" }
            .joined(separator: "\n")
        let wordList = words.joined(separator: ", ")
        return """
        You are embedding vocabulary into an existing English article.
        The article, split into numbered sentences:

        \(numbered)

        Target words: \(wordList)

        For each target word:
        1. ASSOCIATIONS: list 3-5 related images, scenes, or synonyms (comma separated).
        2. Pick the sentence number whose meaning is the best natural home for the word.

        Output ONLY a JSON object, one entry per word, no explanation:
        {"word": {"index": N, "associations": "a, b, c"}, ...}
        """
    }

    /// 宽容解析锚点选句 → [AnchorAssignment]；JSON 无效/词缺失/越界回退默认。
    static func parseAnchors(_ raw: String?, words: [String], count: Int) -> [AnchorAssignment] {
        guard count > 0 else { return [] }
        guard let raw, let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else {
            return defaultAssignments(words: words, count: count)
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return defaultAssignments(words: words, count: count)
        }
        var result: [AnchorAssignment] = []
        for word in words {
            if let entry = obj[word],
               let idx = entry["index"] as? Int,
               idx >= 0, idx < count,
               let assoc = entry["associations"] as? String {
                result.append(AnchorAssignment(word: word, sentenceIndex: idx, associations: assoc))
            } else {
                result.append(AnchorAssignment(word: word, sentenceIndex: 0, associations: ""))
            }
        }
        return result
    }

    private static func defaultAssignments(words: [String], count: Int) -> [AnchorAssignment] {
        words.enumerated().map { i, w in
            AnchorAssignment(word: w, sentenceIndex: min(i, count - 1), associations: "")
        }
    }

    // MARK: - 专注改写

    static func focusedRewritePrompt(
        sentence: String, word: String, associations: String, feedback: [String]?
    ) -> String {
        var prompt = """
        Original sentence: \(sentence)
        Word to include: "\(word)"
        \(associations.isEmpty ? "" : "Word associations: \(associations)\n")
        Rewrite the sentence so that "\(word)" appears naturally. Keep the meaning exactly the same.
        You may use an inflected form (e.g. "abandoned", "battles") if it reads better.
        Do NOT define or explain the word, and do NOT add extra sentences.
        Output ONLY the rewritten sentence.
        """
        if let feedback, !feedback.isEmpty {
            prompt += """

            The previous attempt(s) were rejected for: \(feedback.joined(separator: "; ")).
            Try again, fixing those problems. Output ONLY the rewritten sentence.
            """
        }
        return prompt
    }

    // MARK: - 语义保真验证

    static func verificationPrompt(original: String, rewritten: String) -> String {
        """
        Original sentence: \(original)
        Rewritten sentence: \(rewritten)
        Do these two sentences mean the same thing? Answer ONLY "Yes" or "No", then one short reason.
        """
    }

    /// 解析验证输出：首个词明确为 "no" → false；其余（含 "not sure" 等无法识别）→ true（存在性已由规则把关，不过度拒绝）。
    static func parseVerification(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 取首个词（剥掉尾部标点）；"not sure" 之类以 no 开头但并非否定回答，默认通过
        let firstWord = lower.split(whereSeparator: {
            $0.isWhitespace || $0 == "," || $0 == "." || $0 == ":" || $0 == ";" || $0 == "!" || $0 == "?"
        }).first ?? ""
        return firstWord != "no"
    }

    // MARK: - 局部衔接润色

    static func coherencePrompt(prev: String?, current: String, next: String?) -> String {
        """
        Three consecutive sentences from an article:
        Previous: \(prev ?? "(none)")
        Current: \(current)
        Next: \(next ?? "(none)")
        Smooth the connections between them. You may adjust only transition words and pronouns.
        Do NOT change each sentence's main meaning.
        Output ONLY the three revised sentences, one per line, in order.
        """
    }

    /// 解析润色输出（期望 3 行）；行数不足/无法解析回退原始三句。
    static func parseCoherence(_ raw: String?, prev: String?, current: String, next: String?) -> [String?] {
        guard let raw else { return [prev, current, next] }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if lines.count >= 3 {
            return [lines[0], lines[1], lines[2]]
        }
        if lines.count == 2, prev == nil {
            return [nil, lines[0], lines[1]]
        }
        return [prev, current, next]
    }

    // MARK: - 跳过词结构化报告

    static func skippedReportPrompt(skipped: [SkippedWord]) -> String {
        let list = skipped.map { "- \($0.word) (\($0.reason))" }.joined(separator: "\n")
        return """
        The following target words could not be naturally included in the article:
        \(list)
        Output ONLY a JSON array confirming each word and a short reason:
        [{"word": "...", "reason": "..."}, ...]
        """
    }

    /// 解析跳过报告；失败回退本地记录。
    static func parseSkippedReport(_ raw: String?, fallback: [SkippedWord]) -> [SkippedWord] {
        guard let raw, let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end else {
            return fallback
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return fallback
        }
        let parsed = arr.compactMap { entry -> SkippedWord? in
            guard let word = entry["word"], !word.isEmpty else { return nil }
            return SkippedWord(word: word, reason: entry["reason"] ?? "未能自然融入")
        }
        return parsed.isEmpty ? fallback : parsed
    }

    // MARK: - 长文降级：仅联想（短上下文，本地模型窗口保护）

    /// 只让模型给每个词联想语义场（不包含全文句子，context 极短）。
    static func associationOnlyPrompt(words: [String]) -> String {
        """
        For each word below, list 3-5 related images, scenes, or synonyms (comma separated).
        Output ONLY a JSON object:
        {"word": "a, b, c", ...}
        Words: \(words.joined(separator: ", "))
        """
    }

    /// 解析联想输出；JSON 无效或词缺失回退空字符串。
    static func parseAssociations(_ raw: String?, words: [String]) -> [String: String] {
        guard let raw, let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return [:] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return words.reduce(into: [:]) { acc, w in
            if let v = obj[w], !v.isEmpty { acc[w] = v }
        }
    }

    // MARK: - 输出约定标记

    static let articleStart = "===ARTICLE_START==="
    static let articleEnd = "===ARTICLE_END==="

    /// 提取两个标记之间的正文；标记缺失/半截回退 cleanArticle 全量。
    static func extractMarkedBody(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = s.range(of: articleStart) else {
            return LocalLLMGenerator.cleanArticle(s)
        }
        let inner: String
        if let endRange = s.range(of: articleEnd) {
            inner = String(s[start.upperBound..<endRange.lowerBound])
        } else {
            // 有开标记但结束标记缺失（半截正文）：取开标记之后的内容
            inner = String(s[start.upperBound...])
        }
        let cleaned = LocalLLMGenerator.cleanArticle(inner)
        return cleaned.isEmpty ? LocalLLMGenerator.cleanArticle(s) : cleaned
    }
}
