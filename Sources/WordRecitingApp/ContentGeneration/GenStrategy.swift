import Foundation

// MARK: - 生成策略（由 LLM 策略 pass 决策，规则只解析/执行）

/// 文章生成方式。
enum GenerateStrategyMode: String, Sendable {
    /// 围绕目标词规划并嵌入生成（词与主题相关性强时）。
    case planEmbed = "plan-embed"
    /// 先正常生成（只约束主题+长度），再改写嵌入目标词（词生僻/与主题弱相关时）。
    case generateRewrite = "generate-rewrite"

    /// UI 展示用中文标签。
    var label: String {
        switch self {
        case .planEmbed: return "按计划嵌入"
        case .generateRewrite: return "先写后改写"
        }
    }
}

/// 改写嵌入时一次处理的窗口粒度。
enum RewriteWindow: String, Sendable {
    case sentence
    case paragraph
    case whole

    /// UI 展示用中文标签。
    var label: String {
        switch self {
        case .sentence: return "句子"
        case .paragraph: return "段落"
        case .whole: return "整篇"
        }
    }
}

/// 目标词嵌入不足时的处理。
enum EmbedFallback: String, Sendable {
    /// 跳过不硬塞。
    case skip
    /// 带反馈让模型再试一次。
    case retry

    /// UI 展示用中文标签。
    var label: String {
        switch self {
        case .skip: return "跳过"
        case .retry: return "重试"
        }
    }
}

/// 文章生成策略：模式 + 改写窗口 + 嵌入不足兜底。
/// @ai: 决策权在 LLM（strategyPrompt 输出三行决策），本结构只负责承载与解析。
struct GenStrategy: Sendable, Equatable {
    var mode: GenerateStrategyMode = .planEmbed
    var window: RewriteWindow = .paragraph
    var fallback: EmbedFallback = .skip
}

// MARK: - 策略 prompt 与解析

/// 策略 pass 与改写流程的 prompt 构造。
enum GenStrategyPrompt {

    /// 策略 pass：让 LLM 自己决定生成方式 / 改写窗口 / 嵌入不足处理。
    /// @ai: 输出固定三行（STRATEGY/WINDOW/FALLBACK），便于宽容解析；不写规则硬判。
    ///      主题可留空：空主题时词驱动，直接选 plan-embed（词即主题，无需先写后改写）。
    static func strategyPrompt(theme: String, words: [String]) -> String {
        let wordList = words.isEmpty ? "(none)" : words.joined(separator: ", ")
        let themeLine = theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Theme: (none — the target words ARE the topic)"
            : "Theme: \(theme)"
        return """
        You are the director of an article-generation task.
        \(themeLine)
        Target vocabulary: \(wordList)

        Decide how to write the article so those words appear naturally:

        STRATEGY — choose "plan-embed" when the words relate well to the theme
                   (write the article around them), or "generate-rewrite" when the words
                   are unrelated, rare, or hard to weave in (write a normal article first,
                   then rewrite parts of it to include them).
                   When NO theme is given, always choose "plan-embed": the target words
                   themselves are the topic, so building the article around them is
                   natural and no pre-writing/rewriting is needed.

        WINDOW — for generate-rewrite, how much text to reconsider at a time when
                 inserting a word: "sentence", "paragraph", or "whole".

        FALLBACK — if, after writing, some words still cannot be included naturally:
                   "skip" (leave them out) or "retry" (try once more with feedback).

        IMPORTANT — when the target words are rare, technical, or weakly related to the
                    theme, prefer "generate-rewrite": write a normal on-topic article
                    first, then weave the words in, so the article never drifts off-topic.

        Output ONLY these three lines, no explanation:
        STRATEGY: ...
        WINDOW: ...
        FALLBACK: ...
        """
    }

    /// 宽容解析策略输出（大小写不敏感、容错分隔符与 markdown）。
    /// 无法识别时返回默认 plan-embed / paragraph / skip。
    static func parse(_ raw: String) -> GenStrategy {
        var s = GenStrategy()
        for line in raw.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }) {
            let lower = line.lowercased()
            if lower.hasPrefix("strategy") {
                if lower.contains("generate-rewrite") || lower.contains("rewrite") {
                    s.mode = .generateRewrite
                } else if lower.contains("plan-embed") || lower.contains("plan") {
                    s.mode = .planEmbed
                }
            } else if lower.hasPrefix("window") {
                if lower.contains("sentence") { s.window = .sentence }
                else if lower.contains("whole") { s.window = .whole }
                else if lower.contains("paragraph") { s.window = .paragraph }
            } else if lower.hasPrefix("fallback") {
                if lower.contains("retry") { s.fallback = .retry }
                else if lower.contains("skip") { s.fallback = .skip }
            }
        }
        return s
    }

    /// 第一步：正常生成（只约束主题 + 长度，不要求嵌入任何词）。
    /// @ai: 主题可留空——空主题时让模型自由选材（词驱动改写阶段再嵌词）；
    ///      强制规则块前置（与 LocalLLMGenerator.hardRules 一致，压缩保护常驻）。
    static func plainPrompt(theme: String, maxWords: Int) -> String {
        let topicLine = theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Write a natural, engaging English article on a topic of your choice."
            : "Write a natural, engaging English article about: \(theme)."
        return """
        \(LocalLLMGenerator.hardRules)

        \(topicLine)

        Requirements:
        - Paragraph layout: separate paragraphs with one blank line; write full
          paragraphs (3-5 sentences each). Do NOT leave a single sentence as its own paragraph.
        - Length: about \(maxWords) words.
        - Style: plain, fluent English suitable for an intermediate learner.
        - Output ONLY the article body.
        - Wrap the article exactly with:
          ===ARTICLE_START===
          (article body)
          ===ARTICLE_END===
        - Output nothing outside these markers.
        - You may announce your current action on its own line, starting exactly with
          "THINKING:" (for example "THINKING: writing the opening paragraph"). Such
          lines are removed from the final text, so write the article itself completely.
        """
    }
}
