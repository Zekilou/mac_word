import Foundation
import Observation
import WordRecitingCore

/// 已记录词汇表 ViewModel：列出全局有记录（会/不会/出现过）的词，支持筛选与搜索。
/// @ai: 状态派生统一走 WordMarkState.from，与初始化/RSS 词块口径一致（能力数据统一）。
@MainActor
@Observable
final class VocabularyListViewModel {

    let world: World
    var entries: [GraphQueries.RecordedLemma] = []
    /// 统一筛选状态（由 FilterBar 编辑）。
    /// @ai: 旧的 `Filter` / `SortOrder` enum 与内联过滤已删除——
    ///      筛选逻辑收敛到 `ListFilter`，四个列表共用一份判定。
    var filter = ListFilter()
    var errorMessage: String?

    init(world: World) {
        self.world = world
        reload()
    }

    /// 各状态计数（供列表标题显示）。
    var countByState: (known: Int, unknown: Int, learning: Int, seen: Int) {
        var known = 0, unknown = 0, learning = 0, seen = 0
        for e in entries {
            switch markState(e) {
            case .known: known += 1
            case .unknown: unknown += 1
            case .learning: learning += 1
            case .seen: seen += 1
            case .pending: break
            }
        }
        return (known, unknown, learning, seen)
    }

    func reload() {
        do {
            entries = try world.graph.recordedLemmas()
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = "加载失败：\(error)"
        }
    }

    /// 概率百分比文案（nil = 尚无模型数据）。
    func beliefText(_ e: GraphQueries.RecordedLemma) -> String? {
        guard let belief = e.belief else { return nil }
        return MasteryPresentation.percentText(belief)
    }

    /// 清洗词面显示（剥音标 / 词性尾巴）。
    func displayText(_ e: GraphQueries.RecordedLemma) -> String {
        let cleaned = WordNormalizer.clean(e.text)
        return cleaned.isEmpty ? e.text : cleaned
    }

    /// 统一状态判定（概率优先；无概率回退显式标记）。
    func markState(_ e: GraphQueries.RecordedLemma) -> WordMarkState {
        WordMarkState.from(
            belief: e.belief,
            mastery: e.mastery > 0 ? e.mastery : nil,
            seenCount: e.seenCount)
    }
}
