import SwiftUI
import WordRecitingCore

// MARK: - 可筛选的词属性
//
// @ai: 这是本次 UI 改造的**核心抽象**。全应用有 4 处词列表（词汇表 / 卡片浏览 /
//      造文选词器 / 同义词候选），过去各写一套筛选：
//        · 词汇表   → enum Filter + 内联 switch + 搜索字符串
//        · 卡片浏览 → 只有搜索，无状态筛选
//        · 选词器   → SearchableChecklist 里私有 @State + 内联过滤
//        · 同义词   → 前缀 LIKE 直接在 SQL 里
//      加第 5 个列表只能再抄一遍。这里把「筛选语义」抽成一个值类型 `ListFilter`，
//      判定逻辑只有一份（`matches`），任何列表都能直接用。
//
//      过渡期已结束：所有词列表都派生出同一个 `WordCore`（`CardListItem` / `RecordedLemma` /
//      `LemmaCandidate` / `WordFeatures` 都是它的别名或视图），
//      所以 `FilterableWord` 的实现只有一份（`FilterableAdapters.swift` 里的 `WordCoreBacked`）。
//      新增列表不再需要 adapter——只要它的元素能拿到 `WordCore`。

/// 一个「可以被筛选的词」需要暴露的属性。
/// @ai: 只放筛选真正会用到的字段。不要往这里加业务字段（比如 synonyms）——
///      那会让所有 DTO 为了满足协议去查用不到的数据。
protocol FilterableWord {
    /// 词的稳定身份（用于去重与选中态）。
    var filterID: String { get }
    /// 词面（搜索匹配）。
    var wordText: String { get }
    /// 释义（搜索匹配）。
    var wordDefinition: String? { get }
    /// 掌握度状态（会 / 学习中 / 不会 / 出现过 / 无记录）。
    var wordMark: WordMarkState { get }
    /// BKT 后验概率；nil = 无概率。
    var wordBelief: Double? { get }
    /// 词频带 1..25；nil = 词表外。
    var wordBand: Int? { get }
    /// 出现过次数。
    var wordSeenCount: Int { get }
    /// 词事件总数。
    var wordEventCount: Int { get }
    /// 下次到期时间；nil = 无排程（新卡）。
    var wordDueAt: Date? { get }
    /// 已复习次数。
    var wordReps: Int { get }
    /// 最近更新时间（排序用）。
    var wordUpdatedAt: Date? { get }
}

// 默认实现：让 DTO 只需声明真正有的字段。
extension FilterableWord {
    var wordBelief: Double? { nil }
    var wordBand: Int? { nil }
    var wordSeenCount: Int { 0 }
    var wordEventCount: Int { 0 }
    var wordDueAt: Date? { nil }
    var wordReps: Int { 0 }
    var wordUpdatedAt: Date? { nil }
}

// MARK: - 可筛选的维度

/// 筛选维度。**每个调用点自己声明启用哪些**（`FilterBar(facets: [...])`）。
/// @ai: 这是「全局注册一次、按需启用」的实现：枚举是全集，页面只挑子集。
///      新增维度时在这里加一个 case + 在 `ListFilter.matches` 里加一条判定，
///      所有列表自动获得该能力（只要它的 FilterableWord 实现了对应属性）。
enum WordFacet: String, CaseIterable, Identifiable, Sendable {
    /// 搜索词面。
    case text
    /// 搜索释义。
    case definition
    /// 掌握度状态（多选）。
    case mark
    /// 词频带（多选）。
    case band
    /// BKT 概率区间（多选）。
    case belief
    /// 出现过次数（有记录 / 无记录）。
    case seen
    /// 到期状态（已到期 / 未到期 / 无排程）。
    case due
    /// 排序。
    case sort

    var id: String { rawValue }

    /// 该维度是否需要搜索框（只有文本维度才显示搜索框）。
    var isSearch: Bool { self == .text || self == .definition }

    var label: String {
        switch self {
        case .text: return "搜索"
        case .definition: return "搜索释义"
        case .mark: return "掌握度"
        case .band: return "词频"
        case .belief: return "概率"
        case .seen: return "出现次数"
        case .due: return "到期"
        case .sort: return "排序"
        }
    }
}

// MARK: - 掌握度分组

/// 掌握度的**可筛选分组**。
/// @ai: 直接用 `WordMarkState` 会有个坑——`.learning(Double)` 带关联值，
///      导致相同的「学习中」档位不能放进 Set 比较，且 `.pending` 与 `.seen` 语义重叠。
///      这里归一化成 5 个无关联值的档位，作为筛选键与计数键。
enum WordMarkBucket: String, CaseIterable, Identifiable, Sendable {
    case known
    case learning
    case unknown
    case seen
    case pending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .known: return "会"
        case .learning: return "学习中"
        case .unknown: return "不会"
        case .seen: return "出现过"
        case .pending: return "无记录"
        }
    }

    /// 颜色继续走 `WordMarkState`——全应用掌握度颜色的唯一来源，禁止在这里另配一套。
    var color: Color {
        switch self {
        case .known: return WordMarkState.known.color
        case .learning: return WordMarkState.learning(0.5).color
        case .unknown: return WordMarkState.unknown.color
        case .seen: return WordMarkState.seen.color
        case .pending: return WordMarkState.pending.color
        }
    }

    init(_ state: WordMarkState) {
        switch state {
        case .known: self = .known
        case .learning: self = .learning
        case .unknown: self = .unknown
        case .seen: self = .seen
        case .pending: self = .pending
        }
    }
}

// MARK: - 词频分档

/// 词频带的可筛选分档（把 1..25 带归并成 6 档）。
enum FrequencyBucket: String, CaseIterable, Identifiable, Sendable {
    case top1k, top3k, top5k, top10k, top25k, outside

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top1k: return "1k"
        case .top3k: return "1–3k"
        case .top5k: return "3–5k"
        case .top10k: return "5–10k"
        case .top25k: return "10–25k"
        case .outside: return "表外"
        }
    }

    /// 词频带 → 分档。band 0/负数 = 表外，nil 由调用方处理。
    static func from(band: Int?) -> FrequencyBucket {
        guard let band else { return .outside }
        switch band {
        case ..<1: return .outside
        case 1: return .top1k
        case 2...3: return .top3k
        case 4...5: return .top5k
        case 6...10: return .top10k
        default: return .top25k
        }
    }
}

/// 概率分档（BKT 后验）。
enum BeliefBucket: String, CaseIterable, Identifiable, Sendable {
    case unknown, low, mid, high, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: return "≈0%"
        case .low: return "<35%"
        case .mid: return "35–85%"
        case .high: return "≥85%"
        case .none: return "无概率"
        }
    }

    static func from(belief: Double?) -> BeliefBucket {
        guard let belief else { return .none }
        switch belief {
        case ..<0.20: return .unknown
        case ..<0.35: return .low
        case ..<0.85: return .mid
        default: return .high
        }
    }
}

/// 到期分档。
enum DueBucket: String, CaseIterable, Identifiable, Sendable {
    case overdue, today, future, unscheduled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overdue: return "已逾期"
        case .today: return "今天到期"
        case .future: return "未到期"
        case .unscheduled: return "新卡"
        }
    }

    static func from(dueAt: Date?, now: Date = Date()) -> DueBucket {
        guard let dueAt else { return .unscheduled }
        if dueAt <= now { return .overdue }
        if Calendar.current.isDateInToday(dueAt) { return .today }
        return .future
    }
}

/// 排序方式。
enum WordSort: String, CaseIterable, Identifiable, Sendable {
    case recent, alphabetical, masteryAsc, masteryDesc, bandAsc, seenDesc, dueSoonest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "最近更新"
        case .alphabetical: return "字母序"
        case .masteryAsc: return "掌握度低→高"
        case .masteryDesc: return "掌握度高→低"
        case .bandAsc: return "高频→低频"
        case .seenDesc: return "出现多→少"
        case .dueSoonest: return "最快到期"
        }
    }
}

// MARK: - 筛选状态

/// 筛选状态：一个值类型，页面持有它，`FilterBar` 编辑它，列表消费它。
///
/// @ai: 纯值类型 + 纯函数判定，可单测（`ListFilterTests`）。不要把它做成 ViewModel——
///      页面已经有自己的 VM（加载/写库），筛选是纯 UI 状态，混进去会让 VM 变成杂物间。
struct ListFilter: Equatable, Sendable {

    /// 搜索关键字。
    var query: String = ""
    /// 启用的搜索字段（词面 / 释义）。空 = 只搜词面（默认行为）。
    var searchDefinition: Bool = false

    /// 掌握度（多选，空 = 不限）。
    var marks: Set<WordMarkBucket> = []
    /// 词频带（多选，空 = 不限）。
    var bands: Set<FrequencyBucket> = []
    /// 概率档（多选，空 = 不限）。
    var beliefs: Set<BeliefBucket> = []
    /// 到期档（多选，空 = 不限）。
    var dues: Set<DueBucket> = []
    /// 只看有出现记录的（false = 不限）。
    var onlySeen: Bool = false

    /// 排序。
    var sort: WordSort = .recent

    /// 是否有任何筛选生效（用于显示「清除」按钮与「已筛选 N」）。
    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            || !marks.isEmpty || !bands.isEmpty || !beliefs.isEmpty
            || !dues.isEmpty || onlySeen
    }

    /// 清空所有筛选（保留排序）。
    mutating func clear() {
        query = ""
        marks.removeAll()
        bands.removeAll()
        beliefs.removeAll()
        dues.removeAll()
        onlySeen = false
    }

    // MARK: 判定

    /// 单个词的匹配判定。所有已启用的维度取**交集**，同一维度内取**并集**。
    /// @ai: 同一维度内多选是「或」（会 + 学习中 = 两者都要），
    ///      不同维度之间是「与」（会 + 1k 带 = 既是会又在前 1k）。
    ///      这是筛选器的通行语义，不要改成别的。
    func matches(_ word: some FilterableWord, enabled facets: Set<WordFacet>, now: Date = Date()) -> Bool {
        // 文本搜索
        if facets.contains(.text) || facets.contains(.definition) {
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty {
                var hit = facets.contains(.text) && word.wordText.lowercased().contains(q)
                if !hit, facets.contains(.definition) {
                    hit = word.wordDefinition?.lowercased().contains(q) ?? false
                }
                if !hit { return false }
            }
        }
        // 掌握度
        if facets.contains(.mark), !marks.isEmpty {
            guard marks.contains(WordMarkBucket(word.wordMark)) else { return false }
        }
        // 词频带
        if facets.contains(.band), !bands.isEmpty {
            guard bands.contains(FrequencyBucket.from(band: word.wordBand)) else { return false }
        }
        // 概率档
        if facets.contains(.belief), !beliefs.isEmpty {
            guard beliefs.contains(BeliefBucket.from(belief: word.wordBelief)) else { return false }
        }
        // 到期档
        if facets.contains(.due), !dues.isEmpty {
            guard dues.contains(DueBucket.from(dueAt: word.wordDueAt, now: now)) else { return false }
        }
        // 只看有记录
        if facets.contains(.seen), onlySeen {
            guard word.wordSeenCount > 0 || word.wordEventCount > 0 else { return false }
        }
        return true
    }

    /// 过滤 + 排序。
    func apply<T: FilterableWord>(
        _ words: [T], facets: Set<WordFacet>, now: Date = Date()
    ) -> [T] {
        let filtered = words.filter { matches($0, enabled: facets, now: now) }
        guard facets.contains(.sort) else { return filtered }
        return sorted(filtered)
    }

    /// 排序。
    /// @ai: 所有比较都给了**确定性兜底**（用 filterID 作 tie-breaker），
    ///      否则同分行的顺序在每次重排后随机跳变，列表会「自己抖」。
    func sorted<T: FilterableWord>(_ words: [T]) -> [T] {
        switch sort {
        case .recent:
            return words.sorted {
                let l = $0.wordUpdatedAt ?? .distantPast
                let r = $1.wordUpdatedAt ?? .distantPast
                return l == r ? $0.filterID < $1.filterID : l > r
            }
        case .alphabetical:
            return words.sorted {
                let l = $0.wordText.lowercased(), r = $1.wordText.lowercased()
                return l == r ? $0.filterID < $1.filterID : l < r
            }
        case .masteryAsc:
            return words.sorted {
                let l = $0.wordBelief ?? -1, r = $1.wordBelief ?? -1
                return l == r ? $0.filterID < $1.filterID : l < r
            }
        case .masteryDesc:
            return words.sorted {
                let l = $0.wordBelief ?? -1, r = $1.wordBelief ?? -1
                return l == r ? $0.filterID < $1.filterID : l > r
            }
        case .bandAsc:
            // 表外（band nil）排最后：它们没有词频坐标，不该混在「最高频」里。
            return words.sorted {
                let l = $0.wordBand ?? Int.max, r = $1.wordBand ?? Int.max
                return l == r ? $0.filterID < $1.filterID : l < r
            }
        case .seenDesc:
            return words.sorted {
                let l = $0.wordSeenCount + $0.wordEventCount
                let r = $1.wordSeenCount + $1.wordEventCount
                return l == r ? $0.filterID < $1.filterID : l > r
            }
        case .dueSoonest:
            return words.sorted {
                let l = $0.wordDueAt ?? .distantFuture
                let r = $1.wordDueAt ?? .distantFuture
                return l == r ? $0.filterID < $1.filterID : l < r
            }
        }
    }

    // MARK: 计数

    /// 各掌握度档位的计数（chip 上显示 `会 82`）。
    /// @ai: 计数基于**当前其余筛选条件下**的集合（facet counting），
    ///      否则用户选了词频带之后，掌握度 chip 上的数字还是全量的，会误导。
    func markCounts<T: FilterableWord>(
        _ words: [T], facets: Set<WordFacet>, now: Date = Date()
    ) -> [WordMarkBucket: Int] {
        var counts: [WordMarkBucket: Int] = [:]
        // 计算 mark 计数时忽略 mark 自身的选择。
        var replica = self
        replica.marks = []
        for word in words where replica.matches(word, enabled: facets, now: now) {
            counts[WordMarkBucket(word.wordMark), default: 0] += 1
        }
        return counts
    }

    /// 各词频档的计数。
    func bandCounts<T: FilterableWord>(
        _ words: [T], facets: Set<WordFacet>, now: Date = Date()
    ) -> [FrequencyBucket: Int] {
        var counts: [FrequencyBucket: Int] = [:]
        var replica = self
        replica.bands = []
        for word in words where replica.matches(word, enabled: facets, now: now) {
            counts[FrequencyBucket.from(band: word.wordBand), default: 0] += 1
        }
        return counts
    }

    /// 概率档计数。
    func beliefCounts<T: FilterableWord>(
        _ words: [T], facets: Set<WordFacet>, now: Date = Date()
    ) -> [BeliefBucket: Int] {
        var counts: [BeliefBucket: Int] = [:]
        var replica = self
        replica.beliefs = []
        for word in words where replica.matches(word, enabled: facets, now: now) {
            counts[BeliefBucket.from(belief: word.wordBelief), default: 0] += 1
        }
        return counts
    }
}
