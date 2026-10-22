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
    var cefr: CEFRProgress?
    var errorMessage: String?
    /// 词库数量（首次运行判定用）。
    var deckCount = 0
    /// 全局词汇概览（首次运行判定用）。
    var overview: GraphQueries.MasteryOverview?

    init(world: World) {
        self.world = world
    }

    /// 是否「全新安装」：既没有词库，也没有任何词汇记录。
    /// @ai: 首次启动时首页原本只是一排 0 的空 KPI，新用户不知道从哪开始。
    ///      用「零词库 + 零词汇记录」判定，导入词库或做过词汇初始化后自动消失。
    var isFirstRun: Bool {
        guard deckCount == 0, let overview else { return false }
        return overview.known + overview.unknown + overview.seen == 0
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
            cefr = profile.map { CEFRMapper.progress(families: $0.estimatedKnownTotal) }
            deckCount = (try? world.graph.allDecks().count) ?? 0
            overview = try? world.graph.masteryOverview()
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }
}
