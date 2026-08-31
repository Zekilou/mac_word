import Foundation

/// 词向量提供者（RAG 锚点选句用）。
/// @ai: 与 LLMClient 平级、可插拔——只负责"把文本变成向量"，不参与任何生成。
///      内置 GloVeEmbeddingProvider（随 app 分发）；远端 API 实现可选。
protocol EmbeddingProvider: Sendable {
    /// 单词语向量；查不到返回 nil（调用方走词库数据/LLM 兜底合成）。
    /// @ai: async——远端 API 实现（OpenAI 兼容 /embeddings）需要网络调用；内置表实现直接返回。
    func vector(for word: String) async -> [Float]?
}

/// 向量工具：余弦相似度 + 文本平均向量。
/// @ai: 句子向量 = 词向量加权平均（sentence embedding 标准做法）；
///      词与句在同一向量空间比较才有意义，因此词侧与句侧都用同一 provider。
enum EmbeddingMath {
    /// 余弦相似度（-1...1；任一零向量返回 0）。
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    /// 文本平均向量（分词 → provider 逐词查询 → 平均；查不到的词跳过）。
    /// @ai: 与词库/LLM 合成共用：统一"已知词向量加权平均"语义。
    static func averageVector(of text: String, provider: EmbeddingProvider) async -> [Float]? {
        var sum: [Float] = []
        var count = 0
        let tokens = text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
        for token in tokens {
            guard let v = await provider.vector(for: String(token).lowercased()) else { continue }
            if sum.isEmpty { sum = Array(repeating: 0, count: v.count) }
            for i in 0..<v.count { sum[i] += v[i] }
            count += 1
        }
        guard count > 0, !sum.isEmpty else { return nil }
        for i in 0..<sum.count { sum[i] /= Float(count) }
        return sum
    }
}
