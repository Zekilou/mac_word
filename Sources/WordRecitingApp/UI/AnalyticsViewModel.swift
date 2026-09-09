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
    /// 词频坐标（lemma → 行）。
    private(set) var frequencyByLemma: [EntityID: GraphQueries.LemmaFrequencyRow] = [:]
    var errorMessage: String?

    // MARK: - 记忆质量（二期）

    /// 复习评分明细（保留率 / 评分分布 / 遗忘曲线 / 直方图 / 时段分布）。
    private(set) var reviewRecords: [ReviewRecord] = []
    /// 真实保留率（rating ≥ good 占比）；无复习为 nil。
    private(set) var retention: Double?
    private(set) var ratingDistribution: [RetentionBuilder.RatingSlice] = []
    /// 每日保留率趋势（0~1）。
    private(set) var retentionTrend: [ChartPoint] = []
    private(set) var forgettingCurve: [ChartPoint] = []
    private(set) var intervalBins: [ChartBin] = []
    private(set) var factorBins: [ChartBin] = []

    // MARK: - 学习行为（二期）

    /// 每日快照（热力图 / 复习量 / 连续天数）。
    private(set) var dailyStats: [DailyStat] = []
    private(set) var streak = 0
    private(set) var hourBins: [ChartBin] = []
    /// 最近 30 天复习量。
    private(set) var reviewVolume: [ChartPoint] = []

    // MARK: - 负载预测（三期）

    /// 未来 30 天到期分布（第 0 天 = 今天，含已过期与新卡）。
    private(set) var forecast: [ForecastDay] = []
    private(set) var todayLoad = 0
    private(set) var peakDay: ForecastDay?

    // MARK: - 能力画像（三期）

    private(set) var cefr: CEFRProgress?
    /// 每日收盘词汇量估算趋势（词族）。
    private(set) var vocabularyTrend: [ChartPoint] = []
    /// 掌握度分布趋势（最近 30 天堆叠段）。
    private(set) var masteryTrend: [ChartSegment] = []

    init(world: World) {
        self.world = world
    }

    /// 弱词行的词频带（nil = 无坐标）。
    func band(for stat: WeakLemmaStat) -> Int? {
        frequencyByLemma[stat.lemmaId]?.band
    }

    /// 刷新词汇能力概览 + 复习统计 + 弱词排行。
    func reload() {
        do {
            overview = try world.graph.masteryOverview()
            stats = try world.graph.studyStats()
            weakLemmas = try world.graph.weakLemmaDetails(limit: 10)
            frequencyByLemma = (try? world.graph.allLemmaFrequencies()) ?? [:]
            distribution = try world.graph.masteryDistribution(
                knownThreshold: WordMarkState.knownThreshold,
                unknownThreshold: WordMarkState.unknownThreshold)
            let bandStats = try world.graph.masteryByBand()
            let counts = WordFrequency.bundled?.bandFamilyCounts ?? [:]
            hasFrequencyTable = WordFrequency.bundled != nil
            profile = VocabularyProfileBuilder.build(
                bandStats: bandStats, bandFamilyCounts: counts)
            loadMemoryQuality()
            loadBehavior()
            loadForecast()
            loadAbility()
            errorMessage = nil
        } catch {
            overview = nil
            stats = nil
            weakLemmas = []
            frequencyByLemma = [:]
            distribution = nil
            profile = nil
            resetAnalytics()
            errorMessage = "\(error)"
        }
    }

    /// 记忆质量：保留率 / 评分分布 / 遗忘曲线 / 间隔与因子直方图。
    private func loadMemoryQuality() {
        let records = (try? world.graph.allReviewRecords()) ?? []
        reviewRecords = records
        retention = RetentionBuilder.trueRetention(records)
        ratingDistribution = RetentionBuilder.ratingDistribution(records)
        forgettingCurve = RetentionBuilder.forgettingCurve(records)

        let intervals = records.compactMap(\.lastInterval)
        let maxInterval = intervals.max() ?? 0
        let intervalUpper = max(7, maxInterval.rounded(.up))
        intervalBins = HistogramBuilder.bins(values: intervals, lowerBound: 0,
                                             upperBound: intervalUpper, binCount: 10)
        factorBins = HistogramBuilder.bins(values: records.compactMap(\.factor),
                                           lowerBound: 1.3, upperBound: 3.3, binCount: 10)
    }

    /// 学习行为：日快照 / 连续天数 / 时段分布 / 复习量。
    private func loadBehavior() {
        dailyStats = (try? DailyStatRecorder.loadAll(world: world)) ?? []
        streak = StreakCalculator.current(dailyStats, endingOn: Date())
        hourBins = BehaviorBuilder.hourDistribution(reviewRecords)
        retentionTrend = dailyStats.points(ifPresent: { $0.retention })
        reviewVolume = dailyStats.suffix(30).points { Double($0.reviews) }
    }

    /// 负载预测：复习队列内卡片的到期分布。
    private func loadForecast() {
        let dueDates = (try? world.graph.queueDueDates()) ?? []
        forecast = ForecastBuilder.forecast(dueDates: dueDates, days: 30)
        todayLoad = ForecastBuilder.todayLoad(forecast)
        peakDay = ForecastBuilder.peak(forecast)
    }

    /// 能力画像：CEFR 映射 + 词汇量趋势 + 掌握度分布趋势。
    private func loadAbility() {
        cefr = profile.map { CEFRMapper.progress(families: $0.estimatedKnownTotal) }
        vocabularyTrend = dailyStats.points(ifPresent: { $0.estimatedFamilies })
        masteryTrend = StackedBarBuilder.tierSegments(Array(dailyStats.suffix(30)))
    }

    private func resetAnalytics() {
        reviewRecords = []
        retention = nil
        ratingDistribution = []
        retentionTrend = []
        forgettingCurve = []
        intervalBins = []
        factorBins = []
        dailyStats = []
        streak = 0
        hourBins = []
        reviewVolume = []
        forecast = []
        todayLoad = 0
        peakDay = nil
        cefr = nil
        vocabularyTrend = []
        masteryTrend = []
    }
}
