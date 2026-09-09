import Foundation

/// 纯随机打分（复刻旧 randomPick 行为）。
struct RandomScoring: WordScoringStrategy {
    let id: WordScoringID = .random

    func score(_ f: WordFeatures, context: ScoringContext) -> Double {
        Double.random(in: 0...1)
    }
}
