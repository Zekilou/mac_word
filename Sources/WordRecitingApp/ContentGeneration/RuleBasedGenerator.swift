import Foundation

/// 快速档改写生成器（mode = .rewrite, tier = .fast）。
/// 流程：词形还原 → 精确匹配 Lemma → 查 maps_to 同义词 →
/// 若同义词在目标列表中则替换 → 记录 SpanInfo。
/// @ai: 只读 graph，不写库；落库由 ContentGenSystem 负责。
struct RuleBasedGenerator: ContentGenerator {
    static let identifier = "rule-based"
    static let tier: QualityTier = .fast

    func generate(
        mode: GenerationMode,
        sourceText: String?,
        targetLemmas: [EntityID],
        constraints: GenerationConstraints,
        graph: GraphQueries
    ) async throws -> GeneratedArticle {
        guard mode == .rewrite, let sourceText, !sourceText.isEmpty else {
            return GeneratedArticle(
                body: sourceText ?? "", spans: [],
                generatorId: Self.identifier, tier: Self.tier)
        }
        let targetSet = Set(targetLemmas)
        let chars = Array(sourceText)

        // 1. 分词：连续字母序列为一个词
        var words: [(start: Int, end: Int, text: String)] = []
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                var j = i
                while j < chars.count && chars[j].isLetter { j += 1 }
                words.append((i, j, String(chars[i..<j])))
                i = j
            } else {
                i += 1
            }
        }

        // 2. 逐词处理，构建 body 与 spans
        var body = ""
        var bodyLen = 0
        var lastEnd = 0
        var spans: [SpanInfo] = []
        for w in words {
            let between = String(chars[lastEnd..<w.start])
            body += between
            bodyLen += between.count

            let startOffset = bodyLen
            let result = try processWord(
                w.text, graph: graph, targets: targetSet, constraints: constraints)
            body += result.surfaceForm
            bodyLen += result.surfaceForm.count
            let endOffset = bodyLen

            if let lid = result.lemmaId {
                spans.append(SpanInfo(
                    start: startOffset, end: endOffset,
                    isTarget: true, lemmaId: lid,
                    surfaceForm: result.surfaceForm,
                    replacedFrom: result.replacedFrom,
                    weight: result.weight, sourceType: result.sourceType))
            }
            lastEnd = w.end
        }
        body += String(chars[lastEnd..<chars.count])

        return GeneratedArticle(
            body: body, spans: spans,
            generatorId: Self.identifier, tier: Self.tier)
    }

    // MARK: - 词处理

    private struct WordResult {
        let surfaceForm: String
        let lemmaId: EntityID?
        let replacedFrom: String?
        let weight: Double?
        let sourceType: String?
    }

    private func processWord(
        _ word: String, graph: GraphQueries,
        targets: Set<EntityID>, constraints: GenerationConstraints
    ) throws -> WordResult {
        let lower = word.lowercased()

        // 精确匹配 Lemma
        var lemmaId = try graph.findLemmaId(byTextA: lower)
        // 词形还原匹配
        if lemmaId == nil {
            for form in Self.lemmatize(lower) {
                if let id = try graph.findLemmaId(byTextA: form) {
                    lemmaId = id
                    break
                }
            }
        }
        guard let lid = lemmaId else {
            return WordResult(surfaceForm: word, lemmaId: nil, replacedFrom: nil, weight: nil, sourceType: nil)
        }

        // 目标词直接出现 → 记 span 不替换
        if targets.contains(lid) {
            return WordResult(surfaceForm: word, lemmaId: lid, replacedFrom: nil, weight: nil, sourceType: nil)
        }

        // 查同义词：过滤 weight ≥ synonymDistance，按 source_type 优先级 + weight 降序
        let syns = try graph.synonyms(of: lid)
            .filter { ($0.weight ?? 0) >= constraints.synonymDistance }
            .sorted { a, b in
                let pa = Self.sourceTypePriority(a.sourceType)
                let pb = Self.sourceTypePriority(b.sourceType)
                if pa != pb { return pa < pb }
                return (a.weight ?? 0) > (b.weight ?? 0)
            }
        for syn in syns {
            if targets.contains(syn.lemmaId) {
                let raw = syn.surfaceForm ?? lower
                let adjusted = Self.applyCase(original: word, replacement: raw)
                return WordResult(
                    surfaceForm: adjusted, lemmaId: syn.lemmaId, replacedFrom: word,
                    weight: syn.weight, sourceType: syn.sourceType)
            }
        }
        return WordResult(surfaceForm: word, lemmaId: nil, replacedFrom: nil, weight: nil, sourceType: nil)
    }

    // MARK: - 简单词形还原（英文后缀剥离）

    private static func lemmatize(_ word: String) -> [String] {
        let suffixes = ["ing", "ed", "est", "er", "es", "ly", "s"]
        var results: [String] = []
        for suffix in suffixes {
            if word.count > suffix.count + 2 && word.hasSuffix(suffix) {
                results.append(String(word.dropLast(suffix.count)))
            }
        }
        return results
    }

    // MARK: - 同义词来源优先级（user > wordnet > cedict > 其他）

    private static func sourceTypePriority(_ sourceType: String?) -> Int {
        switch sourceType {
        case "user": return 0
        case "wordnet": return 1
        case "cedict": return 2
        default: return 3
        }
    }

    // MARK: - 保持原文大小写

    private static func applyCase(original: String, replacement: String) -> String {
        guard let firstOrig = original.first, firstOrig.isUppercase,
              let firstRep = replacement.first else {
            return replacement
        }
        return String(firstRep).uppercased() + String(replacement.dropFirst())
    }
}
