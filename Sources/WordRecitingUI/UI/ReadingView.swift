import SwiftUI
import WordRecitingCore

/// 阅读（学习区「阅读」子区，spec §4.2）：来源切换（RSS 源）+ 文章列表 + 阅读词块标记。
/// 核心：文章中的词自动记"出现过"（蓝），不判定会/不会；点击词块才写会/不会。
/// 源配置在「RSS 源」子区（RSSSourceManagerView），本页只负责阅读。
/// @ai: 不用 List/HSplitView（macOS 27 beta 拖分栏崩溃规避）。
struct ReadingView: View {
    let world: World
    @State private var vm: RSSViewModel

    init(world: World) {
        self.world = world
        _vm = State(initialValue: RSSViewModel(world: world))
    }

    /// @ai: 分栏页 → `PageScaffold(scrolls: false)`：骨架只给顶部工具条（源切换 / 刷新 / 图例），
    ///      **不**包滚动、**不**加内容区边距，各栏自己滚、自己处理边缘留白。
    ///      分栏本身走 `SplitPane`（禁用 HSplitView 的等价安全写法），不再手写
    ///      「VStack(spacing: 0) + Rule() + HStack + 固定宽 + Rule + 弹性宽」。
    var body: some View {
        PageScaffold(scrolls: false) {
            topBar
        } content: {
            SplitPane(leadingWidth: Size.paneArticle) {
                articleList
            } trailing: {
                readingPane
            }
        }
        .onAppear { vm.reloadSources() }
    }

    // MARK: - 顶栏：来源切换 + 刷新 + 图例

    /// 顶栏内容（工具条底 / 内边距 / 分隔线由 `PageScaffold` 统一提供）。
    /// @ai: 不再手写 `.padding(Space.m)`——工具条内边距现在是骨架的 `Space.toolbarH/V`，
    ///      与其它页面的工具条左右边距对齐。
    private var topBar: some View {
        VStack(spacing: Space.m) {
            HStack(spacing: Space.l) {
                Picker("", selection: Binding(
                    get: { vm.selectedSourceId ?? "" },
                    set: { vm.selectSource($0) }
                )) {
                    ForEach(vm.sources) { s in
                        Text(s.title).tag(s.id)
                    }
                }
                .frame(maxWidth: 260)
                .disabled(vm.sources.isEmpty)

                IconButton(icon: "arrow.clockwise", help: "刷新文章列表") {
                    vm.fetchSource()
                }

                if vm.isFetchingSource {
                    ProgressView().controlSize(.small)
                }

                Spacer()
                legend
            }
            if let msg = vm.errorMessage {
                Text(msg).font(Type.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var legend: some View {
        WordMarkLegendView()
    }

    // MARK: - 文章列表

    private var articleList: some View {
        VStack(spacing: 0) {
            // 栏头左右内边距对齐 `ListRow`（`Space.rowH`）：原来写的是 `Space.m`，
            // 比下面的文章标题左移 4pt，栏头看起来「飘」在列表外面。
            Text("文章").font(Type.caption).foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.rowH).padding(.vertical, Space.s)
            Rule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.items) { item in
                        articleRow(item)
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.15))
    }

    private func articleRow(_ item: RSSItem) -> some View {
        let selected = vm.selectedItem?.id == item.id
        return ListRow(selected: selected, action: { vm.selectArticle(item) }) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(item.title)
                    .font(Type.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(2)
                if let date = item.pubDate {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(Type.micro).foregroundStyle(Ink.secondary)
                }
            }
        }
    }

    // MARK: - 阅读区

    /// 右栏：文章正文。滚动由本栏自己提供（骨架 `scrolls: false`），
    /// 栏内边距用 `Space.page`——与左栏列表文字、顶部工具条左边界对齐。
    @ViewBuilder
    private var readingPane: some View {
        if let item = vm.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text(item.title)
                        .font(Type.section)
                    HStack(spacing: Space.m) {
                        Text("左键标不会 · 右键改会/不会；未点击的词保持「出现过」")
                            .font(Type.caption).foregroundStyle(Ink.secondary)
                        Spacer()
                    }
                    Rule()
                    if vm.isFetchingArticle {
                        ProgressView().padding(.vertical, Space.xxl)
                    } else {
                        wordCloud
                        continueReading(item)
                    }
                }
                .padding(Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState(
                icon: "newspaper",
                title: "从左侧选择一篇文章开始阅读")
        }
    }

    /// 词块正文（复用 FlowWordsLayout 流式换行）。
    private var wordCloud: some View {
        FlowWordsLayout(spacing: Space.xxs) {
            ForEach(Self.tokens(of: vm.articleText)) { tok in
                if tok.isWord,
                   let word = vm.words.first(where: {
                       $0.lemma == WordNormalizer.normalize(tok.text.lowercased())
                   }) {
                    wordChip(word)
                } else {
                    Text(tok.text).font(Type.reading)
                }
            }
        }
    }

    /// 摘要末尾的「Continue Reading」：RSS 摘要只有一小段，跳系统浏览器看全文。
    @ViewBuilder
    private func continueReading(_ item: RSSItem) -> some View {
        if let url = URL(string: item.link), !item.link.isEmpty {
            VStack(spacing: Space.s) {
                Rule()
                DButton("Continue Reading", rank: .primary, icon: "arrow.right",
                        help: "在浏览器中打开原文") {
                    NSWorkspace.shared.open(url)
                }
                Text("摘要仅一小段，全文请在浏览器中阅读")
                    .font(Type.micro).foregroundStyle(Ink.secondary)
            }
            .padding(.top, Space.m)
            .frame(maxWidth: .infinity)
        }
    }

    /// 可点击词块：会→绿 / 不会→红 / 学习中→掌握度渐变 / 出现过→蓝 / 未见→极淡灰。
    /// @ai: 左键统一标不会（可预测）；改会/不会走右键菜单（可逆操作不用 alert 打断）。
    private func wordChip(_ word: InitWord) -> some View {
        let state = vm.markState(for: word)
        return Button {
            vm.markUnknown(word)
        } label: {
            Text(word.surface)
                .font(Type.reading)
                .padding(.horizontal, Space.xxs)
                .padding(.vertical, Space.xxs)
                .background(state.color.opacity(0.85))
                .foregroundStyle(state == .pending ? Color.primary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("标为会") { vm.setExtreme(word, known: true) }
            Button("标为不会") { vm.setExtreme(word, known: false) }
        }
        .help(helpText(for: state))
    }

    private func helpText(for state: WordMarkState) -> String {
        switch state {
        case .known: return "已会（左键标不会；右键可改）"
        case .unknown: return "不会（右键可改为会）"
        case .learning(let belief): return "\(MasteryPresentation.helpText(belief))；左键标不会，右键改极端"
        case .seen: return "出现过未确认，模型尚无概率（左键标不会）"
        case .pending: return "未见（左键标不会）"
        }
    }

    // MARK: - 分词

    private struct Tok: Identifiable {
        let id: Int
        let text: String
        let isWord: Bool
    }

    private static func tokens(of text: String) -> [Tok] {
        let chars = Array(text)
        var result: [Tok] = []
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter
                    || chars[j] == "-" || chars[j] == "'" { j += 1 }
                result.append(Tok(id: result.count, text: String(chars[i..<j]), isWord: true))
                i = j
            } else {
                let ch = String(chars[i])
                if !ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(Tok(id: result.count, text: ch, isWord: false))
                }
                i += 1
            }
        }
        return result
    }
}
