import Foundation

/// 某个词频带的已观测统计（数据库侧）。
public struct BandStat: Sendable, Equatable {
    /// 词频带：1 = 最高频 1k 带 … 25 = 25k 带；0 = 表外。
    public let band: Int
    /// 该带内已观测（有事件）的词族数。
    public let observedCount: Int
    /// 该带内已观测词的后验概率之和。
    public let sumBelief: Double

    public init(band: Int, observedCount: Int, sumBelief: Double) {
        self.band = band
        self.observedCount = observedCount
        self.sumBelief = sumBelief
    }
}

/// 某个词频带的覆盖率（画像侧）。
public struct BandCoverage: Sendable, Equatable, Identifiable {
    public var id: Int { band }
    public let band: Int
    public let totalFamilies: Int
    public let observedFamilies: Int
    public let meanBelief: Double
    public let estimatedKnownFamilies: Double

    public init(band: Int, totalFamilies: Int, observedFamilies: Int,
                meanBelief: Double, estimatedKnownFamilies: Double) {
        self.band = band
        self.totalFamilies = totalFamilies
        self.observedFamilies = observedFamilies
        self.meanBelief = meanBelief
        self.estimatedKnownFamilies = estimatedKnownFamilies
    }

    /// 覆盖率（估算认识 / 总词族）；总词族为 0 时 nil。
    public var coverage: Double? {
        guard totalFamilies > 0 else { return nil }
        return min(1, estimatedKnownFamilies / Double(totalFamilies))
    }
}

/// 词汇量画像。
public struct VocabularyProfile: Sendable, Equatable {
    public let bands: [BandCoverage]
    public let estimatedKnownTotal: Double
    public let totalFamilies: Int

    public init(bands: [BandCoverage], estimatedKnownTotal: Double, totalFamilies: Int) {
        self.bands = bands
        self.estimatedKnownTotal = estimatedKnownTotal
        self.totalFamilies = totalFamilies
    }
}

/// 画像构建（纯函数，可单测）。
/// @ai: 外推规则（v2）：
///   - 只统计已观测词的后验之和；
///   - 仅当该带观测数 ≥ `minObservedForExtrapolation` 时才把未观测词按**平滑后的实测认识率**外推
///     （rate = sumBelief / (observed + rateSmoothing)），否则该带不外推；
///   - 完全没有观测的带贡献 0。
///   旧版按 `BKTModel.prior` 外推，会把 25000 词族 × 先验质量堆成 ~12.5k 的虚高估计；
///   直接按实测率外推也会被「只收藏自己认识的词」的选择偏差拉爆（14 个观测 × 1000 词族）。
public enum VocabularyProfileBuilder {

    /// 外推所需的最小观测样本（低于此认为证据不足，只统计已观测词）。
    public static let minObservedForExtrapolation = 30
    /// 认识率的平滑伪计数（避免小样本「全对」直接铺满整带）。
    public static let rateSmoothing = 10.0

    public static func build(bandStats: [BandStat],
                      bandFamilyCounts: [Int: Int]) -> VocabularyProfile {
        let observedByBand = Dictionary(
            uniqueKeysWithValues: bandStats.map { ($0.band, $0) })
        let allBands = Set(observedByBand.keys).union(bandFamilyCounts.keys).sorted()

        var coverage: [BandCoverage] = []
        var estimatedTotal = 0.0
        var totalFamilies = 0

        for band in allBands {
            let total = bandFamilyCounts[band] ?? 0
            let stat = observedByBand[band]
            let observed = stat?.observedCount ?? 0
            let sumBelief = stat?.sumBelief ?? 0
            let meanBelief = observed > 0 ? sumBelief / Double(observed) : 0
            let unobserved = max(0, total - observed)

            var estimated = sumBelief
            if observed >= minObservedForExtrapolation, unobserved > 0 {
                let rate = sumBelief / (Double(observed) + rateSmoothing)
                estimated += Double(unobserved) * rate
            }

            coverage.append(BandCoverage(
                band: band,
                totalFamilies: total,
                observedFamilies: observed,
                meanBelief: meanBelief,
                estimatedKnownFamilies: estimated))
            estimatedTotal += estimated
            totalFamilies += total
        }

        return VocabularyProfile(bands: coverage,
                                 estimatedKnownTotal: estimatedTotal,
                                 totalFamilies: totalFamilies)
    }
}
