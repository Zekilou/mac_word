import Foundation

/// 未能自然融入的目标词（结构化报告：词 + 原因）。
struct SkippedWord: Sendable, Equatable {
    let word: String
    let reason: String
}

/// 生成文章的结构化结果：改写或造文后的完整正文 + 目标词 span 信息。
/// @ai: 由 ContentGenerator 产出，交给 ContentGenSystem 落库（plan 仅内存展示，不落库）。
struct GeneratedArticle: Sendable, Equatable {
    let body: String
    let spans: [SpanInfo]
    let generatorId: String
    let tier: QualityTier
    /// 写作前的规划/大纲（规划 pass 产出，仅用于 UI 展示思考过程）。
    var plan: String?
    /// 策略 pass 决策（生成方式/改写窗口/嵌入兜底，仅用于 UI 展示思考链）。
    var strategy: GenStrategy?
    /// 未能自然融入的目标词（模型结构化报告，仅 UI 展示，不落库）。
    var skippedWords: [SkippedWord] = []
}

/// 文章中一个目标词的 span 信息（字符偏移 + 词元映射 + 替换来源）。
struct SpanInfo: Sendable, Equatable {
    /// body 中的起始字符偏移（含）。
    let start: Int
    /// body 中的结束字符偏移（不含）。
    let end: Int
    /// 是否为目标词（替换后的同义词或原文中直接出现的目标词）。
    let isTarget: Bool
    /// 对应的 Lemma EntityID（若有）。
    let lemmaId: EntityID?
    /// 文中实际显示的词。
    let surfaceForm: String
    /// 替换前的原词；nil 表示未替换（原文中本身就是目标词）。
    let replacedFrom: String?
    /// 同义词权重（替换时来自 comp_edge_weighted；nil 表示未替换或无权重）。
    let weight: Double?
    /// 同义词来源类型（user / wordnet / cedict；nil 表示未替换或无来源）。
    let sourceType: String?

    init(
        start: Int, end: Int, isTarget: Bool,
        lemmaId: EntityID?, surfaceForm: String,
        replacedFrom: String?,
        weight: Double? = nil, sourceType: String? = nil
    ) {
        self.start = start
        self.end = end
        self.isTarget = isTarget
        self.lemmaId = lemmaId
        self.surfaceForm = surfaceForm
        self.replacedFrom = replacedFrom
        self.weight = weight
        self.sourceType = sourceType
    }
}

/// 内容生成器协议：造文 / 改写。
/// 实现方只通过 graph: GraphQueries 读取同义词等图信息，**不直接写库**。
/// @ai: 落库由 ContentGenSystem 在 World.run 事务内负责。
protocol ContentGenerator: Sendable {
    /// 生成器唯一标识（如 "rule-based" / "local-llm" / "remote-api"）。
    static var identifier: String { get }
    /// 质量档位：fast / local / remote。
    static var tier: QualityTier { get }
    /// 生成文章。
    /// - Parameters:
    ///   - mode: .generate 造文 / .rewrite 改写
    ///   - sourceText: 源文（改写模式必填，造文模式可空）
    ///   - targetLemmas: 目标词 EntityID 列表
    ///   - constraints: 生成约束（语言 / 同义词距离 / 最大词数等）
    ///   - graph: 图查询服务（只读）
    func generate(
        mode: GenerationMode,
        sourceText: String?,
        targetLemmas: [EntityID],
        constraints: GenerationConstraints,
        graph: GraphQueries
    ) async throws -> GeneratedArticle
}
