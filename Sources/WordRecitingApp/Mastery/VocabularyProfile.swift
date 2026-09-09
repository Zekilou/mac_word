import Foundation

/// 某个词频带的已观测统计（数据库侧）。
struct BandStat: Sendable, Equatable {
    /// 词频带：1 = 最高频 1k 带 … 25 = 25k 带；0 = 表外。
    let band: Int
    /// 该带内已观测（有事件）的词族数。
    let observedCount: Int
    /// 该带内已观测词的后验概率之和。
    let sumBelief: Double
}

/// 某个词频带的覆盖率（画像侧）。
struct BandCoverage: Sendable, Equatable, Identifiable {
    var id: Int { band }
    let band: Int
    let totalFamilies: Int
    let observedFamilies: Int
    let meanBelief: Double
    let estimatedKnownFamilies: Double

    /// 覆盖率（估算认识 / 总词族）；总词族为 0 时 nil。
    var coverage: Double? {
        guard totalFamilies > 0 else { return nil }
        return min(1, estimatedKnownFamilies / Double(totalFamilies))
    }
}

/// 词汇量画像。
struct VocabularyProfile: Sendable, Equatable {
    let bands: [BandCoverage]
    let estimatedKnownTotal: Double
    let totalFamilies: Int
}

/// 画像构建（纯函数，可单测）。
/// @ai: 未观测词用 BKTModel.prior 外推——这是**估计**，不是测量。
enum VocabularyProfileBuilder {

    static func build(bandStats: [BandStat],
                      bandFamilyCounts: [Int: Int],
                      parameters: BKTParameters = .default) -> VocabularyProfile {
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
            let prior = BKTModel.prior(band: band > 0 ? band : nil, parameters: parameters)
            let estimated = sumBelief + Double(unobserved) * prior

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
