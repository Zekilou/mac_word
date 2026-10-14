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

    /// 提取两个标记之间的正文（容错：允许空格/换行/大小写/`<article>` 等变体）；无标记回退全量。
    /// @ai: 先归一化变体标记为规范形式（仅匹配被 =/<> 包裹的标记，不误伤正常短语），再按范围提取；
    /// 开标记之前与结束标记之后的内容一律丢弃；最后剥离前导大纲回显。
    /// **结束标记只在开标记之后查找**——旧实现独立查找两者，若模型先回显了结束标记
    /// （提示词里同时给了 START/END 模板，小模型复读指令是常态），
    /// `start.upperBound > end.lowerBound` 会让切片直接 trap（SIGTRAP 崩溃）。
    static func extractMarkedBody(_ raw: String) -> String {
        let normalized = normalizeMarkers(raw)
        let body: String
        if let start = normalized.range(of: articleStart) {
            let tail = start.upperBound..<normalized.endIndex
            if let endRange = normalized.range(of: articleEnd, range: tail),
               endRange.lowerBound >= start.upperBound {
                body = String(normalized[start.upperBound..<endRange.lowerBound])
            } else {
                // 有开标记但其后没有结束标记（半截正文 / 结束标记出现在开标记之前）：
                // 取开标记之后的内容
                body = String(normalized[start.upperBound...])
            }
        } else {
            body = normalized
        }
        // 剥离前导大纲/计划回显与任务元句（小模型常把写作计划/元评论输出进正文）
        let stripped = stripLeadingJunk(body)
        let cleaned = LocalLLMGenerator.cleanArticle(stripped)
        return cleaned.isEmpty ? LocalLLMGenerator.cleanArticle(normalized) : cleaned
    }

    /// 移除文本中的独立标记行（容错变体）；实时展示用（逐 token 累积后调用，防止标记行闪进流式视图）。
    static func strippingMarkerLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isStartMarker(compactMarker($0)) && !isEndMarker(compactMarker($0)) }
            .joined(separator: "\n")
    }

    /// 剥离前导垃圾块：大纲/计划回显行 + 任务元句 + 前导空行，整块移除。
    /// @ai: 只匹配结构明确的大纲行（Paragraph/Section/Part/Step + 编号 + 冒号）与少数任务元句，
    /// 不枚举"释义的多种表述"；实时守卫与最终提取共用同一判定。
    static func stripLeadingJunk(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start = 0
        while start < lines.count {
            let line = lines[start].trimmingCharacters(in: .whitespaces)
            guard isJunkLeadingLine(line) else { break }
            start += 1
        }
        guard start > 0 else { return body }
        return lines[start...].joined(separator: "\n")
    }

    /// 完整行判定：空行 / 标记行 / 大纲行 / 任务元句。
    static func isJunkLeadingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let compact = compactMarker(trimmed)
        if compact == "articlestart" || compact == "articleend" { return true }
        if isOutlineLine(trimmed) { return true }
        return isMetaPreambleLine(trimmed)
    }

    /// 部分行（尚未换行）是否可能构成垃圾开头：bullet/数字/大纲关键词/任务元句前缀。
    /// @ai: 实时守卫用——普通正文开头立即放行，可疑开头扣留到整行再判定。
    static func startsLikeJunk(_ partial: String) -> Bool {
        let t = partial.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        let lower = t.lowercased()
        if lower.hasPrefix("- ") || lower.hasPrefix("* ") || lower.hasPrefix("• ")
            || lower.hasPrefix("1.") || lower.hasPrefix("2.") || lower.hasPrefix("3.")
            || lower.hasPrefix("4.") || lower.hasPrefix("5.")
            || lower.hasPrefix("paragraph") || lower.hasPrefix("section")
            || lower.hasPrefix("part ") || lower.hasPrefix("step ") { return true }
        return lower.hasPrefix("i'm not sure") || lower.hasPrefix("i am not sure")
            || lower.hasPrefix("i'm having trouble") || lower.hasPrefix("i need help")
            || lower.hasPrefix("i need some help") || lower.hasPrefix("here is my")
            || lower.hasPrefix("here's my") || lower.hasPrefix("here’s my")
            || lower.hasPrefix("my draft") || lower.hasPrefix("my article")
            || lower.hasPrefix("as an ai") || lower.hasPrefix("sure, here")
            || lower.hasPrefix("certainly, here")
    }

    /// 大纲行：以 Paragraph/Section/Part/Step + 编号 + 冒号/句号 开头（允许前置 bullet/数字）。
    static func isOutlineLine(_ line: String) -> Bool {
        guard let re = try? NSRegularExpression(
            pattern: #"^(?:[-*•\d\.\s]*)(?:paragraph|section|part|step)\s*\w*\s*[:：.。]"#,
            options: [.caseInsensitive]) else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return re.firstMatch(in: line, options: [], range: range) != nil
    }

    /// 任务元句：模型自说自话的前缀（对草稿/任务本身的评论），狭窄枚举。
    private static func isMetaPreambleLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasPrefix("i'm not sure") || lower.hasPrefix("i am not sure") { return true }
        if lower.hasPrefix("i'm having trouble") { return true }
        if lower.hasPrefix("i need help") || lower.hasPrefix("i need some help") { return true }
        if lower.hasPrefix("here is my") || lower.hasPrefix("here's my") || lower.hasPrefix("here’s my") { return true }
        if lower.hasPrefix("my draft") || lower.hasPrefix("my article") { return true }
        if lower.hasPrefix("as an ai") || lower.hasPrefix("sure, here") || lower.hasPrefix("certainly, here") { return true }
        return false
    }

    /// 归一化变体标记为规范形式（=== ARTICLE_START === / <article_start> → ===ARTICLE_START===）。
    /// @ai: 正则要求标记被 =/<> 包裹才匹配，start/end 互不干扰；规范模板无 $/\\ 特殊字符，可直接作替换模板。
    private static func normalizeMarkers(_ text: String) -> String {
        let endPattern = #"[=<>]+[^a-z0-9]*article[ _-]*end[^a-z0-9]*[=<>]+"#
        let startPattern = #"[=<>]+[^a-z0-9]*article[ _-]*start[^a-z0-9]*[=<>]+"#
        var out = text
        if let re = try? NSRegularExpression(pattern: endPattern, options: [.caseInsensitive]) {
            out = re.stringByReplacingMatches(
                in: out, options: [], range: NSRange(out.startIndex..., in: out),
                withTemplate: articleEnd)
        }
        if let rs = try? NSRegularExpression(pattern: startPattern, options: [.caseInsensitive]) {
            out = rs.stringByReplacingMatches(
                in: out, options: [], range: NSRange(out.startIndex..., in: out),
                withTemplate: articleStart)
        }
        return out
    }

    /// 归一化标记行：仅保留字母数字并小写（=== ARTICLE_START === / <article_start> → "articlestart"）。
    private static func compactMarker(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func isStartMarker(_ compact: String) -> Bool { compact == "articlestart" }
    private static func isEndMarker(_ compact: String) -> Bool { compact == "articleend" }
}
