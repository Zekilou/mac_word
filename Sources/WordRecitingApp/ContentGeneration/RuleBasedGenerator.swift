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
        // 造文模式：sourceText 作为主题；规则模板快速造文。
        if mode == .generate {
            return try generateArticle(
                topic: sourceText,
                targetLemmas: targetLemmas,
                constraints: constraints,
                graph: graph)
        }
        guard let sourceText, !sourceText.isEmpty else {
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

        // 1.5 多词短语替换（在做单词匹配之前）。
        // @ai: 同义词 lemma 可能是短语（"give up"）。旧实现靠 findLemmaId 的**纯前缀匹配**
        //      才偶然命中（查 "give" 命中 "give up"）——那条路径已按数据正确性收紧
        //      （它会把 blank→blanket 错配），所以短语必须在这里**显式**匹配：
        //      按"最长短语优先"扫描连续词序列，命中则整段替换为目标词表面形式。
        //      结果记在 wordOverrides[起始词下标] = (覆盖词数, 替换词, lemmaId, weight, sourceType)。
        var wordOverrides: [Int: (count: Int, surface: String, lemmaId: EntityID,
                                  replacedFrom: String, weight: Double?, sourceType: String?)] = [:]

        func phraseReplacement(joined: String) throws
            -> (lemmaId: EntityID, surface: String, weight: Double?, sourceType: String?)? {
            // 只在库里确实存在该短语 lemma 时才查同义词（避免每段都打 SQL）
            guard let phraseLemma = try graph.findLemmaId(byTextA: joined),
                  !targetSet.contains(phraseLemma) else { return nil }
            let syns = try graph.synonyms(of: phraseLemma)
                .filter { ($0.weight ?? 0) >= constraints.synonymDistance }
                .sorted { a, b in
                    let pa = Self.sourceTypePriority(a.sourceType)
                    let pb = Self.sourceTypePriority(b.sourceType)
                    if pa != pb { return pa < pb }
                    return (a.weight ?? 0) > (b.weight ?? 0)
                }
            guard let syn = syns.first(where: { targetSet.contains($0.lemmaId) }) else { return nil }
            let raw = syn.surfaceForm ?? joined
            let plain = raw.prefix { ch in ch.isLetter || ch == "-" || ch == "'" }
            return (syn.lemmaId, plain.isEmpty ? raw : String(plain), syn.weight, syn.sourceType)
        }

        if words.count >= 2 {
            var idx = 0
            while idx < words.count {
                var consumed = 0
                let maxLen = min(3, words.count - idx)
                if maxLen >= 2 {
                    for len in stride(from: maxLen, through: 2, by: -1) {
                        let slice = Array(words[idx..<(idx + len)])
                        let joined = slice.map(\.text).joined(separator: " ").lowercased()
                        if let hit = try phraseReplacement(joined: joined) {
                            let surface = Self.applyCase(original: slice[0].text, replacement: hit.surface)
                            wordOverrides[idx] = (len, surface, hit.lemmaId,
                                                  slice.map(\.text).joined(separator: " "),
                                                  hit.weight, hit.sourceType)
                            consumed = len
                            break
                        }
                    }
                }
                idx += consumed > 0 ? consumed : 1
            }
        }

        // 2. 逐词处理，构建 body 与 spans
        var body = ""
        var bodyLen = 0
        var lastEnd = 0
        var spans: [SpanInfo] = []
        var index = 0
        while index < words.count {
            let w = words[index]
            let between = String(chars[lastEnd..<w.start])
            body += between
            bodyLen += between.count

            // 短语命中：整段（count 个词）替换为一个目标词表面形式，
            // 区间文本一并吃掉（含词间空格），并记一条 span。
            if let override = wordOverrides[index] {
                let lastWord = words[index + override.count - 1]
                let originalSpan = String(chars[w.start..<lastWord.end])
                let startOffset = bodyLen
                body += override.surface
                bodyLen += override.surface.count
                spans.append(SpanInfo(
                    start: startOffset, end: bodyLen,
                    isTarget: true, lemmaId: override.lemmaId,
                    surfaceForm: override.surface,
                    replacedFrom: override.replacedFrom,
                    weight: override.weight, sourceType: override.sourceType))
                lastEnd = lastWord.end
                index += override.count
                continue
            }

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
            index += 1
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
                // 清洗尾巴：Anki 清洗后可能仍残留 "[音标]" / "(词性)" 等，
                // 替换用的表面形式只取连续字母 + - + ' 前缀，保证是干净单词。
                let plain = raw.prefix { ch in
                    ch.isLetter || ch == "-" || ch == "'"
                }
                let replacement = plain.isEmpty ? raw : String(plain)
                let adjusted = Self.applyCase(original: word, replacement: replacement)
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
