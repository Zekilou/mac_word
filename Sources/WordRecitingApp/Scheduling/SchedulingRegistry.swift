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
}
