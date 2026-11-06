import SwiftUI
import WordRecitingCore

/// 系统词典查询视图：搜索词 → 懒加载查 macOS 系统词典（英英）→ 展示条目 + 标记会不会。
/// @ai: 交互是"搜索即查"（系统词典无枚举能力）；词块状态/标记与全局掌握度同口径。
struct SystemDictionaryView: View {
    let world: World
    @State private var viewModel: SystemDictionaryViewModel?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                ProgressView().onAppear {
                    viewModel = SystemDictionaryViewModel(world: world)
                    searchFocused = true
                }
            }
        }
        .navigationTitle("系统词典")
    }

    private func content(_ vm: SystemDictionaryViewModel) -> some View {
        // @ai: 搜索条进 `PageScaffold` 工具条槽（工具条底 / 内边距 / 分隔线由骨架统一），
        //      结果区进内容区。页面不再自拼 `VStack(spacing: 0) + Rule() + .padding(...)`。
        //      各结果状态对「是否要占满视口」诉求不同（空态居中 / 条目滚动），
        //      所以骨架只提供非滚动容器，页面级边距与滚动交给各自的 `PageBody`。
        PageScaffold(contentPadding: 0, scrolls: false) {
            searchBar(vm)
        } content: {
            resultArea(vm)
        }
    }

    @ViewBuilder
    private func searchBar(_ vm: SystemDictionaryViewModel) -> some View {
        TextField("输入单词查询（如 abandon）", text: $query)
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)
            .onSubmit { Task { await vm.search(query) } }
        DButton("查询", rank: .primary, icon: "magnifyingglass",
                disabled: query.trimmingCharacters(in: .whitespaces).isEmpty) {
            Task { await vm.search(query) }
        }
    }

    @ViewBuilder
    private func resultArea(_ vm: SystemDictionaryViewModel) -> some View {
        switch vm.phase {
        case .idle:
            // 空态/加载态要占满视口居中，所以不滚动。
            PageBody(scrolls: false) {
                emptyHint("输入单词后从 macOS 系统词典查询英英释义（懒加载，按词查询）")
            }
        case .looking:
            PageBody(scrolls: false) {
                VStack(spacing: Space.m) {
                    ProgressView()
                    Text("正在查询「\(vm.lastQuery)」…")
                        .font(Type.caption).foregroundStyle(Ink.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .notFound(let word):
            PageBody(scrolls: false) {
                emptyHint("系统词典中未找到「\(word)」")
            }
        case .found(let entry):
            // 条目可能很长，由 `PageBody` 提供页面级滚动与边距。
            PageBody {
                entryCard(entry, vm: vm)
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        EmptyState(icon: "character.book.closed", title: text)
    }

    private func entryCard(_ entry: DictionaryEntry, vm: SystemDictionaryViewModel) -> some View {
        // 条目正文：页面级滚动与边距由外层 `PageBody` 提供，此处只保留阅读行宽上限。
        VStack(alignment: .leading, spacing: Space.l) {
            // 词头 + 标记
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(entry.word)
                        .font(Type.displaySmall)
                    HStack(spacing: Space.m) {
                        if let phonetic = entry.phonetic {
                            Text(phonetic).font(Type.title).foregroundStyle(Ink.secondary)
                        }
                        if let pos = entry.partOfSpeech {
                            Text(pos)
                                .font(Type.caption)
                                .padding(.horizontal, Space.s)
                                .padding(.vertical, Space.xxs)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                        }
                    }
                }
                Spacer()
                DButton(
                    vm.wordState == .known ? "已会 ✓" : "标为会",
                    rank: .secondary,
                    help: "当前档位：\(vm.wordState.label)（概率优先判定）。点击切换 会/不会（写入全局掌握度）"
                ) {
                    vm.toggleMark(entry.word)
                }
            }
            // 释义全文
            Text(entry.definition)
                .font(Type.body)
                .textSelection(.enabled)
            Rule()
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.m) {
                    // @ai: 保留手写标题而非 Section——这里标题右侧紧跟「概率徽章」，
                    //      Section 的 trailing 只能放 AnyView 且会改变 baseline 对齐；
                    //      这一处由 HStack 直接管理更准确。属于规范里的「有意例外」。
                    Text("词画像").font(Type.section)
                    if let belief = vm.belief {
                        Text(MasteryPresentation.percentText(belief))
                            .font(Type.captionEmphasis)
                            .monospacedDigit()
                            .foregroundStyle(vm.wordState.color)
                            .padding(.horizontal, Space.s)
                            .padding(.vertical, Space.xxs)
                            .background(vm.wordState.color.opacity(0.14))
                            .clipShape(Capsule())
                            .help(MasteryPresentation.helpText(belief))
                    } else {
                        Text(MasteryPresentation.noDataText)
                            .font(Type.caption)
                            .foregroundStyle(Ink.tertiary)
                    }
                    Text(FrequencyBandPresentation.bandLabel(vm.frequencyBand))
                        .font(Type.micro)
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, Space.xxs)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                        .help(FrequencyBandPresentation.helpText(
                            band: vm.frequencyBand, rank: vm.frequencyRank))
                    Spacer()
                }
                Text("模型估计掌握度 · 词频坐标 · 最近事件（最多 5 条）")
                    .font(Type.caption)
                    .foregroundStyle(Ink.tertiary)
                EventTimelineView(
                    items: vm.recentEvents,
                    emptyText: "这个词还没有事件记录——查词、标记或做题后就会出现")
            }
            Rule()
            Text("数据来源：macOS 系统词典（Dictionary Services）")
                .font(Type.caption)
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}