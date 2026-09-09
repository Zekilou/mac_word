import Foundation
import Observation

/// 分析 ViewModel：词汇能力（全局掌握度）+ 复习表现（卡片统计 + 弱词排行）。
/// @ai: UI 不写 SQL；查询走 GraphQueries 命名方法；词汇能力统一走 masteryOverview。
@MainActor
@Observable
final class AnalyticsViewModel {

    let world: World

    /// 全局掌握度概览（会/不会/出现过/未标记）——与词汇页同一口径。
    var overview: GraphQueries.MasteryOverview?
    var stats: StudyStats?
    var weakLemmas: [WeakLemmaStat] = []
    /// 概率档位分布。
    var distribution: GraphQueries.MasteryDistribution?
    /// 词汇量画像（估算）。
    var profile: VocabularyProfile?
    /// 内置词频表是否已加载。
    var hasFrequencyTable = false
    var errorMessage: String?

    init(world: World) {
        self.world = world
    }

    /// 刷新词汇能力概览 + 复习统计 + 弱词排行。
    func reload() {
        do {
            overview = try world.graph.masteryOverview()
            stats = try world.graph.studyStats()
            weakLemmas = try world.graph.weakLemmaDetails(limit: 10)
            distribution = try world.graph.masteryDistribution(
                knownThreshold: WordMarkState.knownThreshold,
                unknownThreshold: WordMarkState.unknownThreshold)
            let bandStats = try world.graph.masteryByBand()
            let counts = WordFrequency.bundled?.bandFamilyCounts ?? [:]
            hasFrequencyTable = WordFrequency.bundled != nil
            profile = VocabularyProfileBuilder.build(
                bandStats: bandStats, bandFamilyCounts: counts)
            errorMessage = nil
        } catch {
            overview = nil
            stats = nil
            weakLemmas = []
            distribution = nil
            profile = nil
            errorMessage = "\(error)"
        }
    }
}
