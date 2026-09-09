import Foundation

/// 词汇数据维护：启动时的一次性回填（幂等）。
/// @ai: 只在有词频 provider 时执行；失败不影响启动。
enum VocabularyMaintenance {

    /// 为全部 Lemma 回填词频坐标（已打标的会幂等覆盖）。
    static func backfillLemmaFrequency(
        world: World,
        provider: (any WordFrequencyProvider)? = WordFrequency.bundled
    ) {
        guard let provider else { return }
        try? world.run(LemmaFrequencySystem(provider: provider), context: .stampAll)
    }

    /// 为全部 Lemma 重算 BKT 后验（幂等，启动时调用一次）。
    static func backfillMastery(world: World, parameters: BKTParameters = .default) {
        try? world.run(MasterySystem(parameters: parameters), context: .recomputeAll)
    }

    /// 重建每日统计快照（幂等，启动时调用一次）。
    /// @ai: 单遍重放词事件流，与 backfillMastery 同口径；分析页/首页的趋势数据源。
    static func backfillDailyStats(world: World) {
        _ = try? DailyStatRecorder.rebuild(world: world)
    }
}
