import Foundation

/// 简化版 SM-2 排期策略（**逐字复刻** StudySystem 原有公式，保证默认手感不变）。
/// @ai: `stability` 存的是间隔天数、`difficulty` 存的是 SM-2 的 factor（历史字段名沿用）。
struct SM2IntervalPolicy: ReviewIntervalPolicy {
    let id: SchedulerID = .sm2

    func next(state: ScheduleStateComponent, rating: Rating,
              features: WordFeatures, now: Date) -> ScheduleStateComponent {
        let reps = (state.reps ?? 0) + 1
        var lapses = state.lapses ?? 0
        var factor = state.difficulty ?? 2.5
        var interval: Double
        let previousInterval = state.intervalDays ?? 0

        if reps == 1 {
            switch rating {
            case .again: interval = 10.0 / 1440.0
            case .hard: interval = 1
            case .good: interval = 3
            case .easy: interval = 7
            }
        } else {
            switch rating {
            case .again:
                interval = 1
                lapses += 1
                factor = max(1.3, factor - 0.2)
            case .hard:
                interval = previousInterval * max(1.3, factor - 0.15)
            case .good:
                interval = previousInterval * factor
            case .easy:
                interval = previousInterval * factor * 1.3
            }
        }

        return ScheduleStateComponent(
            entityId: state.entityId,
            stability: interval,
            difficulty: factor,
            dueAt: now.addingTimeInterval(interval * 86400),
            intervalDays: interval,
            reps: reps,
            lapses: lapses,
            lastRating: rating.rawValue,
            lastReviewedAt: now,
            schedulerId: id.rawValue,
            queue: interval < 1 ? "learning" : "review",
            customDataJson: nil)
    }
}
