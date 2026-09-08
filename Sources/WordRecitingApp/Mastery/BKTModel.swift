import Foundation

/// 一次观察的发射模型：P(观察到该事件 | 会) 与 P(观察到该事件 | 不会)。
struct BKTObservation: Sendable, Equatable {
    let likelihoodIfKnown: Double
    let likelihoodIfUnknown: Double
}

/// BKT（Bayesian Knowledge Tracing）参数。
/// 参考：Corbett & Anderson (1995) 的四参数 BKT；本实现把 guess/slip 推广为
/// 每种事件的发射矩阵，便于把「标记 / 查词 / 做题 / 被动看到」统一进同一个贝叶斯更新。
/// @ai: 参数为可调启发值，尚未在真实数据上拟合；`version` 变更后需全量重算后验。
struct BKTParameters: Sendable, Equatable, Codable {
    /// 学习转移概率 P(T)：一次机会后由「不会」转为「会」的概率。
    var baseLearnRate: Double
    /// 上下文多样性（不同 region 数）对学习率的加成系数。
    var cdWeight: Double
    /// CD 加成上限（不同 region 数）。
    var cdCap: Int
    /// 无词频坐标时的保守先验 P(L0)。
    var fallbackPrior: Double
    /// 版本号：写入 comp_mastery_belief.params_version。
    var version: String

    static let `default` = BKTParameters(
        baseLearnRate: 0.15,
        cdWeight: 0.10,
        cdCap: 5,
        fallbackPrior: 0.30,
        version: "bkt-1")
}

/// BKT 纯函数实现：先验 → 逐事件贝叶斯后验 + 学习转移 → 重放。
enum BKTModel {

    /// 每种事件的发射模型（启发值，可调）。
    /// @ai: `seen` 是 0.5/0.5 —— 被动看到不提供「会/不会」的证据，
    ///      但它是学习机会，会通过 P(T) 影响后验。
    static func observation(for kind: WordEventKind) -> BKTObservation {
        switch kind {
        case .quizCorrect: return BKTObservation(likelihoodIfKnown: 0.90, likelihoodIfUnknown: 0.15)
        case .quizWrong:   return BKTObservation(likelihoodIfKnown: 0.10, likelihoodIfUnknown: 0.85)
        case .markKnown:   return BKTObservation(likelihoodIfKnown: 0.95, likelihoodIfUnknown: 0.10)
        case .markUnknown: return BKTObservation(likelihoodIfKnown: 0.08, likelihoodIfUnknown: 0.92)
        case .lookup:      return BKTObservation(likelihoodIfKnown: 0.20, likelihoodIfUnknown: 0.70)
        case .seen:        return BKTObservation(likelihoodIfKnown: 0.50, likelihoodIfUnknown: 0.50)
        }
    }

    /// 词频带 → 初始先验 P(L0)。band 1..25 线性映射到 0.90..0.10。
    /// @ai: 映射形状是启发式默认值，不是文献常数。
    static func prior(band: Int?, parameters: BKTParameters = .default) -> Double {
        guard let band else { return parameters.fallbackPrior }
        let clamped = min(max(band, 1), 25)
        return 0.90 - Double(clamped - 1) / 24.0 * 0.80
    }

    /// 上下文多样性加成后的学习率（distinctRegions 越多学得越快，上限 cdCap）。
    static func learnRate(distinctRegions: Int, parameters: BKTParameters = .default) -> Double {
        let capped = min(max(distinctRegions, 1), parameters.cdCap)
        let multiplier = 1.0 + parameters.cdWeight * Double(capped - 1)
        return min(0.95, parameters.baseLearnRate * multiplier)
    }

    /// 单步更新：先按发射模型做贝叶斯后验，再做学习转移。
    /// - Parameter trust: 事件可信度 [0,1]，0 = 无观察信息，1 = 完全按发射模型。
    static func update(belief: Double, kind: WordEventKind, trust: Double,
                       distinctRegions: Int,
                       parameters: BKTParameters = .default) -> Double {
        let clampedBelief = min(max(belief, 0.000_001), 0.999_999)
        let clampedTrust = min(max(trust, 0), 1)
        let raw = observation(for: kind)
        let likelihoodKnown = 0.5 + (raw.likelihoodIfKnown - 0.5) * clampedTrust
        let likelihoodUnknown = 0.5 + (raw.likelihoodIfUnknown - 0.5) * clampedTrust
        let denominator = clampedBelief * likelihoodKnown + (1 - clampedBelief) * likelihoodUnknown
        let posterior = denominator > 0
            ? (clampedBelief * likelihoodKnown) / denominator
            : clampedBelief
        let transition = learnRate(distinctRegions: distinctRegions, parameters: parameters)
        let next = posterior + (1 - posterior) * transition
        return min(max(next, 0.000_001), 0.999_999)
    }

    /// 重放一整条事件流（**必须时间升序**）得到最终后验。
    /// - Parameter distinctRegions: 该词出现过的不同 region 总数（整条流共用一个值）。
    static func replay(events: [(kind: WordEventKind, trust: Double)],
                       prior: Double, distinctRegions: Int,
                       parameters: BKTParameters = .default) -> Double {
        var belief = prior
        for event in events {
            belief = update(belief: belief, kind: event.kind, trust: event.trust,
                            distinctRegions: distinctRegions, parameters: parameters)
        }
        return belief
    }
}
