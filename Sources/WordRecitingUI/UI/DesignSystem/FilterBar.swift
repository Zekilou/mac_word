import SwiftUI
import WordRecitingCore

// MARK: - 统一筛选条
//
// @ai: 这是本次改造的重点。全应用 4 处词列表过去各写一套筛选，能力还各不相同
//      （词汇表有状态筛选、卡片浏览只有搜索、选词器连排序都没有）。
//      这个组件是**唯一**的筛选入口：
//
//        FilterBar(items: vm.words, filter: $vm.filter, facets: [.text, .definition, .mark, .band, .sort])
//
//      三个关键设计：
//        1. **facets 可选**——每个调用点只声明自己要哪些维度，组件按需渲染。
//           想给某个列表加「按词频筛」，把 .band 加进 facets 即可，零额外代码。
//        2. **计数跟随筛选**——chip 上的数字是「在其余筛选条件下有多少个」，
//           不是全量总数（否则选了词频带后，掌握度 chip 的数字是骗人的）。
//        3. **多选取并集**——同一维度内多选是「或」，跨维度是「与」。

struct FilterBar<Item: FilterableWord>: View {
    /// 全量数据（未筛选），用于计数与空态判断。
    let items: [Item]
    /// 筛选状态（由页面持有）。
    @Binding var filter: ListFilter
    /// 启用哪些维度。
    let facets: [WordFacet]
    /// 搜索框占位文案。
    var searchPlaceholder: String = "搜索"

    @FocusState private var searchFocused: Bool

    private var facetSet: Set<WordFacet> { Set(facets) }
    private var showSearch: Bool { facets.contains(where: \.isSearch) }

    /// 当前筛选后的结果（页面直接消费这个）。
    var filtered: [Item] {
        filter.apply(items, facets: facetSet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if showSearch { searchRow }
            if hasChipRow { chipRow }
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.m)
        // ⌘F 聚焦搜索；Esc 清空筛选。
        .onKeyPress(.escape) {
            guard filter.isActive else { return .ignored }
            filter.clear()
            return .handled
        }
        .background {
            // @ai: 用隐藏按钮承接 ⌘F——SwiftUI 的 keyboardShortcut 需要挂在可响应者上。
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var hasChipRow: Bool {
        facets.contains(.mark) || facets.contains(.band)
            || facets.contains(.belief) || facets.contains(.due)
            || facets.contains(.seen) || facets.contains(.sort)
    }

    // MARK: 搜索行

    private var searchRow: some View {
        HStack(spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
                TextField(placeholder, text: $filter.query)
                    .textFieldStyle(.plain)
                    .font(Type.body)
                    .focused($searchFocused)
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Surface.field, in: .rect(cornerRadius: Radius.control))
            .frame(maxWidth: 280)

            // 是否连释义一起搜。
            if facets.contains(.definition) {
                Toggle(isOn: $filter.searchDefinition) {
                    Text("含释义").font(Type.micro)
                }
                .toggleStyle(.checkbox)
                .help("勾选后在释义里也搜索")
            }

            Spacer(minLength: Space.m)

            if facets.contains(.sort) { sortMenu }
            countLabel
            if filter.isActive {
                Button {
                    filter.clear()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除全部筛选（Esc）")
            }
        }
    }

    private var placeholder: String {
        facets.contains(.definition) && filter.searchDefinition
            ? "搜索词或释义" : searchPlaceholder
    }

    // MARK: chip 行

    private var chipRow: some View {
        HStack(spacing: Space.s) {
            if facets.contains(.mark) { markChips }
            if facets.contains(.band) { bandMenu }
            if facets.contains(.belief) { beliefMenu }
            if facets.contains(.due) { dueChips }
            if facets.contains(.seen) { seenToggle }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private var markChips: some View {
        let counts = filter.markCounts(items, facets: facetSet)
        return ForEach(WordMarkBucket.allCases) { bucket in
            let n = counts[bucket] ?? 0
            // @ai: 计数为 0 的档位不渲染——四个「0」chip 只会制造噪音。
            //      但已选中的必须保留，否则用户无法取消它。
            if n > 0 || filter.marks.contains(bucket) {
                Chip(
                    text: bucket.label,
                    tint: bucket.color,
                    selected: filter.marks.contains(bucket),
                    count: n,
                    action: { toggle(bucket, in: &filter.marks) }
                )
            }
        }
    }

    private var bandMenu: some View {
        let counts = filter.bandCounts(items, facets: facetSet)
        return Menu {
            ForEach(FrequencyBucket.allCases) { bucket in
                let n = counts[bucket] ?? 0
                Button {
                    toggle(bucket, in: &filter.bands)
                } label: {
                    // 菜单项用勾选标记表示已选（Menu 里塞不了 Chip）。
                    HStack {
                        Text("\(bucket.label)  \(n)")
                        if filter.bands.contains(bucket) { Image(systemName: "checkmark") }
                    }
                }
                .disabled(n == 0 && !filter.bands.contains(bucket))
            }
            if !filter.bands.isEmpty {
                Divider()
                Button("清除词频筛选") { filter.bands.removeAll() }
            }
        } label: {
            menuLabel("词频", active: !filter.bands.isEmpty,
                      summary: filter.bands.isEmpty ? nil : "\(filter.bands.count)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var beliefMenu: some View {
        let counts = filter.beliefCounts(items, facets: facetSet)
        return Menu {
            ForEach(BeliefBucket.allCases) { bucket in
                let n = counts[bucket] ?? 0
                Button {
                    toggle(bucket, in: &filter.beliefs)
                } label: {
                    HStack {
                        Text("\(bucket.label)  \(n)")
                        if filter.beliefs.contains(bucket) { Image(systemName: "checkmark") }
                    }
                }
                .disabled(n == 0 && !filter.beliefs.contains(bucket))
            }
            if !filter.beliefs.isEmpty {
                Divider()
                Button("清除概率筛选") { filter.beliefs.removeAll() }
            }
        } label: {
            menuLabel("概率", active: !filter.beliefs.isEmpty,
                      summary: filter.beliefs.isEmpty ? nil : "\(filter.beliefs.count)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var dueChips: some View {
        ForEach(DueBucket.allCases) { bucket in
            Chip(
                text: bucket.label,
                tint: bucket == .overdue ? .red : (bucket == .today ? .orange : Ink.secondary),
                selected: filter.dues.contains(bucket),
                action: { toggle(bucket, in: &filter.dues) }
            )
        }
    }

    private var seenToggle: some View {
        Chip(
            text: "只看有记录",
            tint: Ink.secondary,
            selected: filter.onlySeen,
            action: { filter.onlySeen.toggle() }
        )
    }

    private var sortMenu: some View {
        Menu {
            ForEach(WordSort.allCases) { s in
                Button {
                    filter.sort = s
                } label: {
                    HStack {
                        Text(s.label)
                        if filter.sort == s { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            menuLabel("排序", active: filter.sort != .recent, summary: nil,
                      fixedText: filter.sort.label)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("排序方式")
    }

    private func menuLabel(
        _ title: String, active: Bool, summary: String?, fixedText: String? = nil
    ) -> some View {
        HStack(spacing: Space.xxs) {
            Text(fixedText ?? title).font(Type.micro)
            if let summary {
                Text(summary).font(Type.mono)
            }
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .foregroundStyle(active ? Color.accentColor : Ink.secondary)
        .padding(.horizontal, Space.chipH)
        .padding(.vertical, Space.chipV)
        .background(
            (active ? Color.accentColor.opacity(0.10) : Surface.field),
            in: .rect(cornerRadius: Radius.chip)
        )
    }

    private var countLabel: some View {
        let shown = filtered.count
        let all = items.count
        return Text(shown == all ? "\(all)" : "\(shown) / \(all)")
            .font(Type.mono)
            .foregroundStyle(filter.isActive ? Color.accentColor : Ink.tertiary)
            .help("已筛选 / 总数")
    }

    /// 多选切换。
    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

// MARK: - 便捷：自带空态的词列表

/// 筛选条 + 列表 + 空态的组合。
/// @ai: 四个词列表的**全部**结构都在这里，页面只提供行视图和 facets：
///
///     WordListPane(items: vm.words, filter: $vm.filter,
///                  facets: [.text, .definition, .mark, .band, .sort],
///                  emptyTitle: "还没有词汇记录") { word in
///         WordRow(word) { ... }
///     }
struct WordListPane<Item: FilterableWord & Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var filter: ListFilter
    let facets: [WordFacet]
    var searchPlaceholder: String = "搜索"
    var emptyIcon: String = "text.book.closed"
    var emptyTitle: String = "暂无内容"
    var emptyMessage: String? = nil
    var rowSpacing: CGFloat = 0
    @ViewBuilder let row: (Item) -> Row

    private var bar: FilterBar<Item> {
        FilterBar(items: items, filter: $filter, facets: facets,
                  searchPlaceholder: searchPlaceholder)
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rule()
            let results = bar.filtered
            if items.isEmpty {
                EmptyState(icon: emptyIcon, title: emptyTitle, message: emptyMessage)
            } else if results.isEmpty {
                // @ai: 「搜不到」与「本来就没数据」是两种状态，必须分开——
                //      否则用户以为数据丢了。这里给出恢复入口。
                EmptyState(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "没有匹配的词",
                    message: "当前筛选条件下没有结果。",
                    actionLabel: "清除筛选",
                    action: { filter.clear() })
            } else {
                ScrollView {
                    LazyVStack(spacing: rowSpacing) {
                        ForEach(results) { item in
                            row(item)
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
            }
        }
    }
}

// MARK: - 标准词行

/// 标准词行：状态点 + 词面 + 释义 + 右侧徽章。
/// @ai: 四个列表的行长得几乎一样却各写一遍（列宽、字号、徽章位置都不同）。
///      这里定死：点 7pt、词面 emphasis、释义 caption 次要色单行、右侧徽章。
struct WordRow<Trailing: View>: View {
    let text: String
    let definition: String?
    let mark: WordMarkState
    var selected: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ListRow(selected: selected, action: action) {
            HStack(spacing: Space.m) {
                StatusDot(color: mark.color)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(text)
                        .font(Type.emphasis)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let definition, !definition.isEmpty {
                        Text(definition)
                            .font(Type.caption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Space.m)
                trailing()
            }
        }
    }
}

extension WordRow where Trailing == EmptyView {
    init(text: String, definition: String?, mark: WordMarkState,
         selected: Bool = false, action: (() -> Void)? = nil) {
        self.init(text: text, definition: definition, mark: mark,
                  selected: selected, action: action) { EmptyView() }
    }
}
