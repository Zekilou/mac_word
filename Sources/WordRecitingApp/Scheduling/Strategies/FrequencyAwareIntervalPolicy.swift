import Foundation

/// SM-2 + 词频/概率调制。
/// @ai: 三个倍数是**启发式默认值**（非文献常数），集中在此便于调参：
///      高频词（band ≤ 3）在语料中自然复现多 → 拉长 30%；
///      低频词（band ≥ 10）复现少 → 缩短 20%；
///      模型高置信（belief ≥ 0.9）且非 again/hard → 额外拉长 50%。
///      `again` 不调制（重置到 1 天是刻意的）。
struct FrequencyAwareIntervalPolicy: ReviewIntervalPolicy {
    let id: SchedulerID = .sm2Frequency

    /// 高频带上界（含）。
    static let highFrequencyMaxBand = 3
    /// 低频带下界（含）。
    static let lowFrequencyMinBand = 10
    static let highFrequencyMultiplier = 1.3
    static let lowFrequencyMultiplier = 0.8
    static let highConfidenceMultiplier = 1.5
    static let highConfidenceThreshold = 0.9

    private let base = SM2IntervalPolicy()

    func next(state: ScheduleStateComponent, rating: Rating,
              features: WordFeatures, now: Date) -> ScheduleStateComponent {
        let baseResult = base.next(state: state, rating: rating,
                                   features: features, now: now)
        guard rating != .again else { return stamped(baseResult) }

        var multiplier = 1.0
        if let band = features.band, band >= 1 {
            if band <= Self.highFrequencyMaxBand {
                multiplier *= Self.highFrequencyMultiplier
            } else if band >= Self.lowFrequencyMinBand {
                multiplier *= Self.lowFrequencyMultiplier
            }
        }
        if let belief = features.belief,
           belief >= Self.highConfidenceThreshold,
           rating.rawValue >= Rating.good.rawValue {
            multiplier *= Self.highConfidenceMultiplier
        }
        guard multiplier != 1.0 else { return stamped(baseResult) }

        let interval = (baseResult.intervalDays ?? 0) * multiplier
        return ScheduleStateComponent(
            entityId: baseResult.entityId,
            stability: interval,
            difficulty: baseResult.difficulty,
            dueAt: now.addingTimeInterval(interval * 86400),
            intervalDays: interval,
            reps: baseResult.reps,
            lapses: baseResult.lapses,
            lastRating: baseResult.lastRating,
            lastReviewedAt: baseResult.lastReviewedAt,
            schedulerId: id.rawValue,
            queue: interval < 1 ? "learning" : "review",
            customDataJson: nil)
    }

    /// 把 schedulerId 标成本策略（未调制时也要标，便于回放归因）。
    private func stamped(_ state: ScheduleStateComponent) -> ScheduleStateComponent {
        var copy = state
        copy.schedulerId = id.rawValue
        return copy
    }
}
