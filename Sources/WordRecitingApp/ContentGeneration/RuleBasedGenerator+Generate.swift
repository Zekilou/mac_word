import Foundation

/// RuleBasedGenerator 的快速造文（mode = .generate, tier = .fast）。
/// 思路：给定主题 + 目标词，用内置句子模板拼装一篇短文，
/// 每个目标词至少出现一次并打上 span（isTarget=true）。
/// 注意：这是离线快速档，质量有限；阶段二用 LocalLLMGenerator 替代。
/// @ai: 只读 graph，不写库；落库由 ContentGenSystem 负责。
extension RuleBasedGenerator {

    /// 造文用句子模板：%topic 主题占位，%w 单词占位。
    private static let openingTemplates: [String] = [
        "When we talk about %topic, one thing stands out immediately.",
        "There is a quiet revolution happening in %topic these days.",
        "Almost everyone has an opinion about %topic, and for good reason.",
    ]

    private static let bodyTemplates: [String] = [
        "People often find that %w plays a bigger role in %topic than they expected.",
        "A closer look at %topic shows how important %w really is.",
        "Experts in %topic agree that %w cannot be ignored any longer.",
        "For anyone new to %topic, %w is a good place to start.",
        "The connection between %topic and %w is stronger than most realize.",
        "Some argue that %w defines the future of %topic.",
    ]

    private static let closingTemplates: [String] = [
        "In the end, %topic will keep evolving — and the ideas above will stay at its core.",
        "Whether we like it or not, all of this is part of how %topic moves forward.",
    ]

    /// 快速造文：sourceText 作主题（若非空），否则用 constraints.topic。
    func generateArticle(
        topic: String?,
        targetLemmas: [EntityID],
        constraints: GenerationConstraints,
        graph: GraphQueries
    ) throws -> GeneratedArticle {
        let theme = Self.resolveTopic(topic: topic, constraints: constraints)
        let surfaces = try graph.lemmaSurfaces(for: targetLemmas)
        guard !surfaces.isEmpty else {
            return GeneratedArticle(
                body: "", spans: [],
                generatorId: Self.identifier, tier: Self.tier)
        }

        // 1. 组装句子：开头 + 每个目标词一句 + 结尾
        var sentences: [String] = []
        sentences.append(Self.fill(Self.openingTemplates.randomElement()!, theme: theme))
        for (i, lemmaId) in targetLemmas.enumerated() {
            guard let word = surfaces[lemmaId] else { continue }
            let template = Self.bodyTemplates[i % Self.bodyTemplates.count]
            sentences.append(Self.fill(template, theme: theme, word: word))
        }
        sentences.append(Self.fill(Self.closingTemplates.randomElement()!, theme: theme))
        let body = sentences.joined(separator: " ")
        let chars = Array(body)

        // 2. 扫描 body 中的目标词，生成 spans（大小写不敏感，按真实偏移）
        let targetsSet = Set(targetLemmas)
        let surfaceLookup: [String: EntityID] = surfaces.reduce(into: [:]) { acc, kv in
            acc[kv.value.lowercased()] = kv.key
        }
        var spans: [SpanInfo] = []
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                var j = i
                while j < chars.count && chars[j].isLetter { j += 1 }
                let word = String(chars[i..<j]).lowercased()
                if let lid = surfaceLookup[word], targetsSet.contains(lid) {
                    spans.append(SpanInfo(
                        start: i, end: j, isTarget: true, lemmaId: lid,
                        surfaceForm: String(chars[i..<j]),
                        replacedFrom: nil, weight: nil, sourceType: nil))
                }
                i = j
            } else {
                i += 1
            }
        }

        return GeneratedArticle(
            body: body, spans: spans,
            generatorId: Self.identifier, tier: Self.tier)
    }

    // MARK: - 模板工具

    private static func resolveTopic(topic: String?, constraints: GenerationConstraints) -> String {
        let t = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t, !t.isEmpty { return t }
        return constraints.topic ?? "this subject"
    }

    /// 填充模板：%topic 与 %w 占位替换。
    private static func fill(_ template: String, theme: String, word: String? = nil) -> String {
        var s = template.replacingOccurrences(of: "%topic", with: theme)
        if let word {
            s = s.replacingOccurrences(of: "%w", with: word)
        }
        return s
    }
}
