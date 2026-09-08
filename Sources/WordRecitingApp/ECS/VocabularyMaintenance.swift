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
}
