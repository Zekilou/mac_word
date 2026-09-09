import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                articleList
                    .frame(width: 270)
                Divider()
                readingPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { vm.reloadSources() }
    }

    // MARK: - 顶栏：来源切换 + 刷新 + 图例

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
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

                Button {
                    vm.fetchSource()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新文章列表")

                if vm.isFetchingSource {
                    ProgressView().controlSize(.small)
                }

                Spacer()
                legend
            }
            if let msg = vm.errorMessage {
                Text(msg).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    private var legend: some View {
        WordMarkLegendView()
    }

    // MARK: - 文章列表

    private var articleList: some View {
        VStack(spacing: 0) {
            Text("文章").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
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
        return Button {
            vm.selectArticle(item)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(2)
                if let date = item.pubDate {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 阅读区

    @ViewBuilder
    private var readingPane: some View {
        if let item = vm.selectedItem {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title)
                            .font(.headline)
                        HStack(spacing: 8) {
                            Text("左键标不会 · 右键改会/不会；未点击的词保持「出现过」")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        Divider()
                        if vm.isFetchingArticle {
                            ProgressView().padding(.vertical, 20)
                        } else {
                            wordCloud
                            continueReading(item)
                        }
                    }
                    .padding(14)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "newspaper")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("从左侧选择一篇文章开始阅读")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 词块正文（复用 FlowWordsLayout 流式换行）。
    private var wordCloud: some View {
        FlowWordsLayout(spacing: 3) {
            ForEach(Self.tokens(of: vm.articleText)) { tok in
                if tok.isWord,
                   let word = vm.words.first(where: {
                       $0.lemma == WordNormalizer.normalize(tok.text.lowercased())
                   }) {
                    wordChip(word)
                } else {
                    Text(tok.text).font(.system(size: 16))
                }
            }
        }
    }

    /// 摘要末尾的「Continue Reading」：RSS 摘要只有一小段，跳系统浏览器看全文。
    @ViewBuilder
    private func continueReading(_ item: RSSItem) -> some View {
        if let url = URL(string: item.link), !item.link.isEmpty {
            VStack(spacing: 6) {
                Divider()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Continue Reading", systemImage: "arrow.right")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .help("在浏览器中打开原文")
                Text("摘要仅一小段，全文请在浏览器中阅读")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
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
                .font(.system(size: 16))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(state.color.opacity(0.85))
                .foregroundStyle(state == .pending ? Color.primary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
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
