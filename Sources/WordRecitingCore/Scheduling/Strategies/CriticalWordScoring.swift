import Foundation

/// 临界词优先：概率越接近 0.5（会不会的边缘）越该练。
/// @ai: 动机——两端（0.05 / 0.95）练它边际收益最低；无概率时给中性 0.5。
struct CriticalWordScoring: WordScoringStrategy {
    let id: WordScoringID = .criticalWords

    func score(_ f: WordFeatures, context: ScoringContext) -> Double {
        guard let belief = f.belief else { return 0.5 }
        return 1 - abs(belief - 0.5) / 0.5
    }
}
