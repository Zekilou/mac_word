import Foundation

/// 语义锚点合成器：为任意目标词生成词向量（伪向量）。
/// @ai: 优先级——① 内置词向量直接命中；② 词库数据（释义/例句/同义词）合成；
///      ③ LLM 辅助伪向量（让 LLM 给出近义词 → 用表内词平均）兜底。
///      与 EmbeddingAnchorMatcher 解耦：本模块只负责"词 → 向量"。
struct SemanticAnchorComposer {
    let provider: EmbeddingProvider
    /// 生成 LLM（LLM 辅助伪向量兜底用；nil = 禁用该级）。
    let llm: (any LLMClient)?
    let graph: GraphQueries

    init(provider: EmbeddingProvider, llm: (any LLMClient)?, graph: GraphQueries) {
        self.provider = provider
        self.llm = llm
        self.graph = graph
    }

    /// 为词合成向量。word 为表面形式，lemmaId 用于查词库数据。
    /// @ai: 三步依次尝试，返回第一个成功者；全部失败返回 nil（调用方 skip）。
    func vector(for word: String, lemmaId: EntityID) async -> [Float]? {
        // ① 直接命中内置表
        if let v = await provider.vector(for: word) { return v }
        // ② 词库数据合成
        if let v = await anchorFromLexicon(word: word, lemmaId: lemmaId) { return v }
        // ③ LLM 辅助伪向量（anchorFromLLM 内部自己判 llm 是否可用）
        if let v = await anchorFromLLM(word: word) { return v }
        return nil
    }

    /// 从词库数据合成：释义 + 例句 + maps_to 同义词 → 表内已知词 → 平均。
    /// @ai: 词库数据（Anki 卡片/词典释义）是"专为该词定制的上下文"，比通用表更贴词义。
    private func anchorFromLexicon(word: String, lemmaId: EntityID) async -> [Float]? {
        var texts: [String] = []
        // 释义（comp_lemma_definitions 多来源 + comp_text.text_b 主释义）
        if let detail = try? graph.lemmaDetail(lemmaId) {
            if let def = detail.definition, !def.isEmpty { texts.append(def) }
            texts.append(contentsOf: detail.synonyms.compactMap(\.surfaceForm))
        }
        if let entries = try? graph.lemmaDefinitions(lemmaId: lemmaId) {
            texts.append(contentsOf: entries.map(\.definition))
        }
        // 词面本身也可能含释义尾巴（如 "abandon[音标] 放弃"）
        texts.append(word)
        guard !texts.isEmpty else { return nil }
        return await Self.average(of: texts, provider: provider)
    }

    /// LLM 辅助伪向量：让 LLM 给出 3-5 个近义词/近义短语，用表内已知词平均。
    /// @ai: 覆盖生僻词/短语；单次小调用（maxTokens 120）。LLM 输出不可靠时静默回退。
    private func anchorFromLLM(word: String) async -> [Float]? {
        guard let llm else { return nil }
        let prompt = """
        Give 5 common English synonyms or near-phrases for the word or phrase: \(word)
        Output ONLY the words/phrases, comma separated, no explanation.
        """
        guard let raw = try? await llm.complete(
            prompt: prompt, maxTokens: 120, temperature: 0.2), !raw.isEmpty else { return nil }
        let candidates = raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        return await Self.average(of: candidates, provider: provider)
    }

    /// 多段文本 → 平均向量（各段先平均再总体平均，避免长文本主导）。
    private static func average(of texts: [String], provider: EmbeddingProvider) async -> [Float]? {
        var vecs: [[Float]] = []
        for t in texts {
            if let v = await EmbeddingMath.averageVector(of: t, provider: provider) {
                vecs.append(v)
            }
        }
        guard !vecs.isEmpty else { return nil }
        let dim = vecs[0].count
        var sum = [Float](repeating: 0, count: dim)
        for v in vecs {
            for i in 0..<dim { sum[i] += v[i] }
        }
        for i in 0..<dim { sum[i] /= Float(vecs.count) }
        return sum
    }
}
