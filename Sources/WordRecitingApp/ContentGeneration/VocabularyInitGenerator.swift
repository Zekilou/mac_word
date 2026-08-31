import Foundation

/// 词汇初始化段落生成器：用 LLM 生成易读英文段落，供用户标记会/不会。
/// 难度分级：.intro（最简，只用高频基础词）/ .medium（普通日常词）。
/// @ai: 只读生成不落库；词元提取走 WordNormalizer 归一化去重（变体归并到同一 Lemma）。
enum InitEase: String, Sendable, CaseIterable {
    case intro
    case medium

    var label: String {
        switch self {
        case .intro: return "更简单"
        case .medium: return "普通"
        }
    }
}

/// 初始化段落产物：正文 + 提取出的词元（去重保序）。
struct InitParagraph: Sendable {
    let paragraph: String
    let words: [InitWord]
}

/// 段中的一个词元：原文表面形式 + 归一化词形（提交时用 lemma 落库）。
struct InitWord: Identifiable, Equatable, Sendable {
    let surface: String
    let lemma: String
    var id: String { lemma }
}

/// 初始化段落生成器（注入任意 LLMClient）。
struct VocabularyInitGenerator {
    let client: any LLMClient
    let maxTokens: Int

    /// maxTokens 默认 600：目标段落 ≥100 词（约 140+ tokens），小模型本地输出快，
    /// 不必省 token 把上限压死导致段落被截断；余量充足也容忍模型的思考/铺垫。
    init(client: any LLMClient, maxTokens: Int = 600) {
        self.client = client
        self.maxTokens = maxTokens
    }

    /// 预置话题池：每次生成随机挑一个，保证"重新生成"产出不同内容（小模型对同一 prompt 易趋同）。
    static let topics = [
        "your morning routine",
        "a simple meal you make",
        "a trip to the market",
        "what you do after work",
        "a walk in the park",
        "your day at school or work",
        "visiting a friend",
        "a rainy day at home",
    ]

    /// 随机挑一个话题（供调用方每次重新生成时变化）。
    static func randomTopic() -> String {
        topics.randomElement() ?? topics[0]
    }

    /// 生成一段指定难度的英文，并提取词元。
    /// - Parameter feedback: 上一版生成的反馈（如"已有词重复过多"），重试时传给 LLM 让其改进；nil 为首轮。
    /// @ai: 慢思考——先让模型输出 PLAN: 计划（用词/句子大纲），再把计划带进正文 prompt；
    /// 模型未按格式输出 PLAN: 或规划调用失败时静默回退单次生成（不阻塞、不显示思考日志）。
    func generate(ease: InitEase, topic: String = randomTopic(),
                  feedback: String? = nil) async throws -> InitParagraph {
        // 规划 pass（低温度，输出 PLAN: 前缀的计划）
        var plan: String?
        if let rawPlan = try? await client.complete(
            prompt: Self.planPrompt(ease: ease, topic: topic, feedback: feedback),
            maxTokens: 100, temperature: 0.3),
           let p = Self.cleanPlan(rawPlan), !p.isEmpty {
            plan = p
        }
        let raw = try await client.complete(
            prompt: Self.prompt(ease: ease, topic: topic, feedback: feedback, plan: plan),
            maxTokens: maxTokens, temperature: 0.9)
        let paragraph = Self.clean(raw)
        guard !paragraph.isEmpty else {
            throw InitGenerateError.emptyParagraph
        }
        return InitParagraph(paragraph: paragraph, words: Self.extractWords(paragraph))
    }

    // MARK: - Prompt

    /// 规划 pass prompt：让模型先联想用词与句子大纲，再写正文（慢思考）。
    /// @ai: 要求输出 "PLAN:" 前缀；feedback（重试）时规划也避开已知词。
    static func planPrompt(ease: InitEase, topic: String, feedback: String? = nil) -> String {
        var base = """
        Before writing, plan a short simple English paragraph about \(topic).
        List 3-5 everyday content words you will use, then outline 4-6 short sentences
        that use them naturally.
        Reply with 'PLAN:' followed by your plan (under 60 words).
        Do NOT write the paragraph yet.
        """
        if ease == .intro {
            base += "\nUse ONLY the most common 500 English words."
        }
        if let feedback, !feedback.isEmpty {
            base += "\n\n" + feedback
        }
        return base
    }

    /// 从模型输出提取计划：剥 "PLAN:" 前缀；无前缀视为规划失败返回 nil。
    static func cleanPlan(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = s.range(of: "PLAN:", options: .caseInsensitive) else { return nil }
        let plan = String(s[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return plan.isEmpty ? nil : plan
    }

    /// 初始化段落 prompt：指定话题 + 只用高频基础词 + 可选的重试反馈 + 可选规划。
    /// @ai: feedback 用于"已有词重复过多"时的改进引导——告知已用过的词并换话题，而非硬塞指定词。
    static func prompt(ease: InitEase, topic: String, feedback: String? = nil,
                       plan: String? = nil) -> String {
        var base: String
        switch ease {
        case .intro:
            base = """
            Write a long simple English passage about \(topic) (at least 100 words in total).
            Use ONLY the most common 500 English words (like: get, go, eat, see, day, home, good, want).
            No rare or academic words. Keep each sentence short (under 8 words).
            Output ONLY the passage, no title, no word list, no explanations.
            """
        case .medium:
            base = """
            Write a full simple paragraph (at least 100 words in total) of natural English about \(topic).
            Use only common everyday words (verbs like take, make, find,
            give; nouns like work, friend, money, morning; adjectives like happy, tired).
            Avoid rare, technical, or academic vocabulary. Output ONLY the paragraph,
            no title, no word list, no explanations.
            """
        }
        if let plan, !plan.isEmpty {
            base += "\n\nFollow this plan:\n" + plan
        }
        if let feedback, !feedback.isEmpty {
            base += "\n\n" + feedback
        }
        return base
    }

    // MARK: - 功能词判断（评估"已有词出现率"时排除）

    /// 常见功能词（冠词/代词/be 助动词/介词/连词/高频副词等）。
    /// @ai: 评估新词率时只统计内容词，功能词高频正常出现，不影响"新词"指标。
    static let functionWords: Set<String> = [
        "a", "an", "the", "my", "your", "his", "her", "its", "our", "their",
        "this", "that", "these", "those", "i", "you", "he", "she", "it", "we",
        "they", "me", "him", "us", "them", "who", "what", "when", "where",
        "why", "how", "which", "whom",
        "am", "is", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "done", "have", "has", "had", "having",
        "and", "but", "or", "so", "if", "then", "than", "as", "of", "at",
        "by", "for", "from", "in", "on", "to", "with", "without", "about",
        "into", "over", "under", "between", "through",
        "not", "no", "yes", "ok", "okay", "up", "down", "out", "off",
        "again", "here", "there", "now", "very", "just", "really", "too",
        "quite", "also", "only", "still", "even", "much", "more", "most",
        "one", "two", "three",
    ]

    /// 是否为功能词（评估"已有实词"时排除）。
    static func isFunctionWord(_ lemma: String) -> Bool {
        functionWords.contains(lemma)
    }

    /// 构造重试反馈：告知上一版太短 / 重复了哪些已有词，要求写长 + 换话题 + 换词。
    /// @ai: 只列已有实词（前 15 个）；强调保持自然，避免生硬塞词；tooShort 时引导写够长。
    static func feedbackMessage(knownWords: [String], tooShort: Bool = false,
                                contentCount: Int = 0) -> String {
        var parts: [String] = []
        if tooShort {
            parts.append(
                "Note: the previous paragraph was too short (only \(contentCount) words). " +
                "Write a FULL paragraph: at least 100 words in total.")
        }
        if !knownWords.isEmpty {
            let words = knownWords.prefix(15).joined(separator: ", ")
            parts.append(
                "Note: the previous paragraph reused too many words the reader already knows " +
                "(like: \(words)). Write a NEW version on a DIFFERENT topic with DIFFERENT " +
                "content words — avoid those words above, prefer words the reader has not seen " +
                "yet, but keep the sentences simple and natural (no awkward phrasing).")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 输出清洗

    /// 去掉 markdown 围栏 / 前导说明 / 多余空白（与 LocalLLMGenerator.cleanArticle 同策略）。
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 折叠 3+ 连续换行为段落空行
        while s.contains("\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        // 每行 trim，去行内多余空白
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n")
    }

    // MARK: - 词元提取

    /// 段落实际词数（含功能词、不去重）——长度合格判定用（extractWords 去重后偏小，不能反映真实长度）。
    /// @ai: 分词口径与 extractWords 一致：字母 + - + '。
    static func wordCount(_ text: String) -> Int {
        let chars = Array(text)
        var count = 0
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                while i < chars.count, chars[i].isLetter
                    || chars[i] == "-" || chars[i] == "'" { i += 1 }
                count += 1
            } else {
                i += 1
            }
        }
        return count
    }

    /// 从段落提取词元：分词（字母 + - + '）→ 小写归一化 → 去重保序。
    /// @ai: 变体（battles/battle）归一后合并为同一词元，提交时按 lemma 落库。
    static func extractWords(_ text: String) -> [InitWord] {
        let chars = Array(text)
        var seen = Set<String>()
        var result: [InitWord] = []
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter
                    || chars[j] == "-" || chars[j] == "'" { j += 1 }
                let surface = String(chars[i..<j])
                let lemma = WordNormalizer.normalize(surface)
                if !lemma.isEmpty, seen.insert(lemma).inserted {
                    result.append(InitWord(surface: surface, lemma: lemma))
                }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }
}

enum InitGenerateError: Error, Sendable, Equatable {
    /// LLM 返回空 / 全清洗后为空。
    case emptyParagraph
}
