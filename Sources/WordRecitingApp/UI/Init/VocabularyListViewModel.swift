import Foundation
import Observation

/// 已记录词汇表 ViewModel：列出全局有记录（会/不会/出现过）的词，支持筛选与搜索。
/// @ai: 状态派生统一走 WordMarkState.from，与初始化/RSS 词块口径一致（能力数据统一）。
@MainActor
@Observable
final class VocabularyListViewModel {

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case known = "会"
        case unknown = "不会"
        case seen = "出现过"
        var id: String { rawValue }
    }

    /// 词表排序：最近更新 / 阅读频次高→低 / 低→高。
    enum SortOrder: String, CaseIterable, Identifiable {
        case recent = "最近更新"
        case frequent = "阅读多→少"
        case rare = "阅读少→多"
        var id: String { rawValue }
    }

    let world: World
    var entries: [GraphQueries.RecordedLemma] = []
    var filter: Filter = .all
    var sortOrder: SortOrder = .recent
    var searchText = ""
    var errorMessage: String?

    init(world: World) {
        self.world = world
        reload()
    }

    /// 按筛选 + 搜索 + 排序后的条目。
    var filtered: [GraphQueries.RecordedLemma] {
        let base = entries.filter { e in
            let state = state(of: e)
            let matchFilter: Bool
            switch filter {
            case .all: matchFilter = true
            case .known: matchFilter = state == .known
            case .unknown: matchFilter = state == .unknown
            case .seen: matchFilter = state == .seen
            }
            guard matchFilter else { return false }
            let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return true }
            return e.text.lowercased().contains(q)
                || (e.definition?.lowercased().contains(q) ?? false)
        }
        switch sortOrder {
        case .recent:
            return base   // entries 已按 updated_at DESC
        case .frequent:
            return base.sorted { $0.seenCount > $1.seenCount }
        case .rare:
            return base.sorted { $0.seenCount < $1.seenCount }
        }
    }

    /// 各状态计数（供列表标题显示）。
    var countByState: (known: Int, unknown: Int, learning: Int, seen: Int) {
        var known = 0, unknown = 0, learning = 0, seen = 0
        for e in entries {
            switch state(of: e) {
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

    /// 清洗词面显示（剥音标 / 词性尾巴）。
    func displayText(_ e: GraphQueries.RecordedLemma) -> String {
        let cleaned = WordNormalizer.clean(e.text)
        return cleaned.isEmpty ? e.text : cleaned
    }

    /// 统一状态判定（有 mastery 才判会/不会，否则 seen / 无记录）。
    private func state(of e: GraphQueries.RecordedLemma) -> WordMarkState {
        WordMarkState.from(
            mastery: e.mastery > 0 ? e.mastery : nil,
            seenCount: e.seenCount)
    }
}
