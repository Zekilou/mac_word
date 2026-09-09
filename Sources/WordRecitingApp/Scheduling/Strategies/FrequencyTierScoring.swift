import Foundation

/// 词频分层：词频带越小（越高频）越优先；带窗口外直接 0。
/// @ai: 无词频坐标（band == nil）给 0，排在最后——宁可不用它，也不猜。
struct FrequencyTierScoring: WordScoringStrategy {
    let id: WordScoringID = .frequencyTier

    func score(_ f: WordFeatures, context: ScoringContext) -> Double {
        guard let band = f.band, band >= 1 else { return 0 }
        if let window = context.bandWindow, !window.contains(band) { return 0 }
        return 1 - Double(band - 1) / 24.0
    }
}
