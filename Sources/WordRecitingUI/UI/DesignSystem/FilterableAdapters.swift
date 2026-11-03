import Foundation
import WordRecitingCore

// MARK: - 统一筛选的 conformance
//
// @ai: 全应用的词列表以前用三个字段残缺各不相同的 DTO，统一筛选只能给每个 DTO 各写一次
//      conformance（本项目历史上的 `FilterableAdapters` 临时脚手架），其中缺失的字段返回空值，
//      对应的筛选项在部分列表里「沉默不生效」。
//
//      现在所有词列表都派生出同一个 `WordCore`，所以**属性的实现只有一份**：
//      任何持有 `word: WordCore` 的类型，只要声明 `WordCoreBacked` 就自动获得全部筛选属性，
//      只剩 `filterID`（身份）需要自己说清楚。新增词列表因此不需要再写 adapter。

/// 能拿到词快照的类型。
/// @ai: 只要求 `word` 一个属性——DTO 里那个 `let word: WordCore` 直接满足它。
protocol WordCoreBacked {
    var word: WordCore { get }
}

/// **唯一一份**筛选属性实现。
extension FilterableWord where Self: WordCoreBacked {
    var wordText: String { word.text }
    var wordDefinition: String? { word.definition }
    var wordMark: WordMarkState { word.markState }
    var wordBelief: Double? { word.belief }
    var wordBand: Int? { word.band }
    var wordSeenCount: Int { word.seenCount }
    var wordEventCount: Int { word.eventCount }
    var wordDueAt: Date? { word.schedule?.dueAt }
    var wordReps: Int { word.schedule?.reps ?? 0 }
    var wordUpdatedAt: Date? { word.updatedAt }
}

// MARK: - 词快照本身

extension WordCore: WordCoreBacked, FilterableWord {
    var word: WordCore { self }
    var filterID: String { lemmaId }
}

// MARK: - 派生 DTO

/// 卡片行：筛选身份用 **cardId**（同一词的多张卡是不同行，去重/选中态不能按词算），
/// 词面用纯词形（与行内展示一致）。
extension WordCore.Card: WordCoreBacked, FilterableWord {
    var filterID: String { cardId }
    var wordText: String { plainText }
}

extension GraphQueries.RecordedLemma: WordCoreBacked, FilterableWord {
    var filterID: String { lemmaID }
}

extension LemmaCandidate: WordCoreBacked, FilterableWord {
    var filterID: String { lemmaId }
}

/// 卡片行：内部持有 `WordCore`，所以筛选属性与词列表**完全同源**。
///
/// @ai: 这个 extension 以前是手写的（因为 `CardListItem` 只平铺了 10 个字段，
///      没有 `WordCore`，词频带等维度只能留空）。现在 `CardListItem` 已收敛到
///      `WordCore`，于是只剩「身份用 cardId」这一处差异。
///      至此**全工程只有一份** FilterableWord 实现（`WordCoreBacked` 的默认实现）。
extension CardListItem: WordCoreBacked, FilterableWord {
    var filterID: String { cardId }
    // 词面用纯词形（与行内展示一致；WordCore.text 可能带音标尾巴）
    var wordText: String { plainText }
}
