import Foundation

/// 按策略打分取词（纯函数）。
/// @ai: 同分时按 lemmaId 升序稳定排序，保证结果可复现。
enum WordSelector {

    /// 取分数最高的前 n 个。
    static func top(_ n: Int, from features: [WordFeatures],
                    strategy: any WordScoringStrategy,
                    context: ScoringContext) -> [EntityID] {
        guard n > 0, !features.isEmpty else { return [] }
        return ranked(features, strategy: strategy, context: context)
            .prefix(n)
            .map(\.lemmaId)
    }

    /// 取分数 ≥ threshold 的全部（按分数降序）。
    static func above(_ threshold: Double, from features: [WordFeatures],
                      strategy: any WordScoringStrategy,
                      context: ScoringContext) -> [EntityID] {
        ranked(features, strategy: strategy, context: context)
            .filter { $0.score >= threshold }
            .map(\.lemmaId)
    }

    private static func ranked(_ features: [WordFeatures],
                               strategy: any WordScoringStrategy,
                               context: ScoringContext) -> [(lemmaId: EntityID, score: Double)] {
        features
            .map { (lemmaId: $0.lemmaId, score: strategy.score($0, context: context)) }
            .sorted {
                $0.score == $1.score ? $0.lemmaId < $1.lemmaId : $0.score > $1.score
            }
    }
}
