import Foundation

/// 锚点匹配结果：词 → 最贴合句子索引 + 相似度分数。
struct EmbeddingAnchor: Sendable {
    let word: String
    let sentenceIndex: Int
    let score: Float
}

/// Embedding 余弦相似度锚点匹配器（RAG 选锚）。
/// @ai: 核心逻辑——把每个目标词和每句话映射到同一向量空间，余弦相似度选最高分句；
///      低于阈值（词与任何句子都不贴合）返回 -1（调用方 skip，不硬塞）。
///      这是对现有 localAnchorMatch（词面重叠）的语义升级：同义词/近义也能匹配上。
struct EmbeddingAnchorMatcher {
    /// 词向量合成（内置表 → 词库数据 → LLM 兜底）。
    let composer: SemanticAnchorComposer
    /// 句子侧用同一 provider（保证同一向量空间）。
    let provider: EmbeddingProvider
    /// 相似度阈值：低于则判定"融不进去"（skip）。0.3~0.4 为经验区间。
    var threshold: Float = 0.35

    init(composer: SemanticAnchorComposer, provider: EmbeddingProvider, threshold: Float = 0.35) {
        self.composer = composer
        self.provider = provider
        self.threshold = threshold
    }

    /// 为一批目标词选锚点。
    /// - Parameters:
    ///   - words: 目标词 → lemmaId（词向量合成需词库数据）。
    ///   - sentences: 草稿切句后的句子列表。
    /// - Returns: 每词的最贴合锚点；`sentenceIndex == -1` = 低于阈值，调用方跳过。
    func match(words: [String: EntityID], sentences: [String]) async -> [EmbeddingAnchor] {
        guard !sentences.isEmpty else { return [] }
        // 句子向量预计算（只算一次）
        var sentenceVecs: [[Float]?] = []
        for s in sentences {
            sentenceVecs.append(await EmbeddingMath.averageVector(of: s, provider: provider))
        }
        var result: [EmbeddingAnchor] = []
        result.reserveCapacity(words.count)
        for (word, lemmaId) in words {
            guard let wordVec = await composer.vector(for: word, lemmaId: lemmaId) else {
                // 词向量都合不成 → 无法判断贴合度 → 跳过（保守）
                result.append(EmbeddingAnchor(word: word, sentenceIndex: -1, score: 0))
                continue
            }
            var best = -1
            var bestScore: Float = -1
            for (idx, sVec) in sentenceVecs.enumerated() {
                guard let sVec else { continue }
                let score = EmbeddingMath.cosine(wordVec, sVec)
                if score > bestScore {
                    bestScore = score
                    best = idx
                }
            }
            result.append(EmbeddingAnchor(
                word: word,
                sentenceIndex: bestScore >= threshold ? best : -1,
                score: bestScore))
        }
        return result
    }

    /// 同句去重：已占用句子顺延到下一高分空闲句（防多词挤一句）。
    /// @ai: 返回后处理——按分数降序占用，冲突词顺延；无空闲则标记 skip。
    func deconflict(_ anchors: [EmbeddingAnchor]) -> [EmbeddingAnchor] {
        let sorted = anchors.sorted { $0.score > $1.score }
        var used = Set<Int>()
        var result: [EmbeddingAnchor] = []
        for a in sorted {
            guard a.sentenceIndex >= 0 else {
                result.append(a)
                continue
            }
            if used.contains(a.sentenceIndex) {
                result.append(EmbeddingAnchor(word: a.word, sentenceIndex: -1, score: a.score))
            } else {
                used.insert(a.sentenceIndex)
                result.append(a)
            }
        }
        return result
    }
}
