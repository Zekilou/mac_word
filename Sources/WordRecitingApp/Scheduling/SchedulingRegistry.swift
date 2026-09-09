import Foundation

/// 策略注册表：id → 实现。
/// @ai: 每个枚举 case 都必须有实现，`ScoringStrategiesTests` 会遍历 allCases 校验。
enum SchedulingRegistry {

    static func scoring(_ id: WordScoringID) -> any WordScoringStrategy {
        switch id {
        case .random: return RandomScoring()
        case .criticalWords: return CriticalWordScoring()
        case .frequencyTier: return FrequencyTierScoring()
        }
    }

    static func reviewPolicy(_ id: SchedulerID) -> any ReviewIntervalPolicy {
        switch id {
        case .sm2: return SM2IntervalPolicy()
        case .sm2Frequency: return FrequencyAwareIntervalPolicy()
        // FSRS 未实现：先回退 SM-2，避免设置成 fsrs 后无策略可用。
        case .fsrsV4: return SM2IntervalPolicy()
        }
    }
}
