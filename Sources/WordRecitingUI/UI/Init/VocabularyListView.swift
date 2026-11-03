import SwiftUI
import WordRecitingCore

/// 已记录词汇表：列出全局有记录的词（会/不会/出现过），筛选 + 搜索 + 掌握度/释义/来源。
/// @ai: 不用 List（macOS 27 beta 拖分栏崩溃规避），列表用 ScrollView + LazyVStack。
struct VocabularyListView: View {
    @State private var vm: VocabularyListViewModel

    init(world: World) {
        _vm = State(initialValue: VocabularyListViewModel(world: world))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = vm.errorMessage {
                InlineError(message: err)
                    .padding(.horizontal, Space.page)
                    .padding(.vertical, Space.s)
            }
            // @ai: 统一筛选条。词汇表现在字段齐全（`RecordedLemma` 派生自 `WordCore`），
            //      所以 `.band`（词频）与 `.due`（到期）都能启用——
            //      此前这两个维度因为 DTO 缺字段而「沉默不生效」。
            WordListPane(
                items: vm.entries,
                filter: $vm.filter,
                facets: [.text, .definition, .mark, .band, .belief, .due, .seen, .sort],
                searchPlaceholder: "搜索词或释义",
                emptyIcon: "text.book.closed",
                emptyTitle: "还没有词汇记录",
                emptyMessage: "在「初始化段落」标记词汇，或阅读 RSS 文章后，这里会列出所有有记录的词。"
            ) { entry in
                wordRow(entry)
            }
        }
    }

    /// 列表行：状态点 + 词面 + 释义 + 右侧元信息。
    private func wordRow(_ e: GraphQueries.RecordedLemma) -> some View {
        // @ai: 状态口径收敛到 `WordCore.markState`——它内部就是
        //      `WordMarkState.from(belief:mastery:seenCount:)` 并处理 mastery=0（无记录）的情形，
        //      词表不再各写一遍「mastery > 0 ? mastery : nil」。
        let state = e.word.markState
        return WordRow(
            text: vm.displayText(e),
            definition: e.definition,
            mark: state
        ) {
            if let belief = e.belief {
                Text(MasteryPresentation.percentText(belief))
                    .font(Type.mono)
                    .foregroundStyle(state.color)
                    .help(MasteryPresentation.helpText(belief))
            }
            if let src = e.source {
                Chip(text: src, tint: Ink.secondary)
            }
            if e.eventCount > 0 {
                Text("\(e.contextCount) 上下文 · \(e.eventCount) 事件")
                    .font(Type.micro)
                    .foregroundStyle(Ink.tertiary)
                    .help("上下文多样性：在 \(e.contextCount) 个不同场景出现过，累计 \(e.eventCount) 次事件。CD 研究表明多样性比单纯频次更能预测学习。")
            }
        }
    }

}
