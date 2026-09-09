import Foundation
import Observation

/// 首页 ViewModel：只给「今天该做什么」的判断 + 一屏结论，深度数据在分析页。
/// @ai: 与分析页同源同口径（`WordMarkState` 阈值 + `DailyStatRecorder` 快照）。
@MainActor
@Observable
final class HomeViewModel {
    let world: World

    var distribution: GraphQueries.MasteryDistribution?
    var stats: StudyStats?
    var dailyStats: [DailyStat] = []
    var streak = 0
    var weakLemmas: [WeakLemmaStat] = []
    var profile: VocabularyProfile?
    var errorMessage: String?

    init(world: World) {
        self.world = world
    }

    /// 今天的快照（无活动时也有，记录当前收盘状态）。
    var todayStat: DailyStat? { dailyStats.last }

    /// 「已会」趋势（最近 30 个快照点）。
    var knownTrend: [ChartPoint] {
        dailyStats.suffix(30).points { Double($0.known) }
    }

    /// 今日保留率（无复习为 nil）。
    var todayRetention: Double? { todayStat?.retention }

    func reload() {
        do {
            distribution = try world.graph.masteryDistribution(
                knownThreshold: WordMarkState.knownThreshold,
                unknownThreshold: WordMarkState.unknownThreshold)
            stats = try world.graph.studyStats()
            dailyStats = try DailyStatRecorder.loadAll(world: world)
            streak = StreakCalculator.current(dailyStats, endingOn: Date())
            weakLemmas = try world.graph.weakLemmaDetails(limit: 3)
            let bandStats = try world.graph.masteryByBand()
            let counts = WordFrequency.bundled?.bandFamilyCounts ?? [:]
            profile = VocabularyProfileBuilder.build(bandStats: bandStats, bandFamilyCounts: counts)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }
}
