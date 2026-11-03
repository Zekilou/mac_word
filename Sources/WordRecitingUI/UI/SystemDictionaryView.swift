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
        VStack(spacing: 0) {
            searchBar(vm)
            Rule()
            resultArea(vm)
        }
    }

    private func searchBar(_ vm: SystemDictionaryViewModel) -> some View {
        HStack(spacing: Space.m) {
            TextField("输入单词查询（如 abandon）", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { Task { await vm.search(query) } }
            Button {
                Task { await vm.search(query) }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.toolbarV)
    }

    @ViewBuilder
    private func resultArea(_ vm: SystemDictionaryViewModel) -> some View {
        switch vm.phase {
        case .idle:
            emptyHint("输入单词后从 macOS 系统词典查询英英释义（懒加载，按词查询）")
        case .looking:
            VStack(spacing: Space.m) {
                ProgressView()
                Text("正在查询「\(vm.lastQuery)」…").font(Type.caption).foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound(let word):
            emptyHint("系统词典中未找到「\(word)」")
        case .found(let entry):
            entryCard(entry, vm: vm)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: Space.m) {
            Image(systemName: "character.book.closed")
                .font(IconSize.empty)
                .foregroundStyle(Ink.tertiary)
            Text(text)
                .font(Type.caption)
                .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func entryCard(_ entry: DictionaryEntry, vm: SystemDictionaryViewModel) -> some View {
        ScrollView {
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
                    Button {
                        vm.toggleMark(entry.word)
                    } label: {
                        Text(vm.wordState == .known ? "已会 ✓" : "标为会")
                    }
                    .buttonStyle(.bordered)
                    .tint(vm.wordState.color)
                    .help("当前档位：\(vm.wordState.label)（概率优先判定）。点击切换 会/不会（写入全局掌握度）")
                }
                // 释义全文
                Text(entry.definition)
                    .font(Type.body)
                    .textSelection(.enabled)
                Rule()
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(spacing: Space.m) {
                        Text("词画像").font(Type.section)
                        if let belief = vm.belief {
                            Text(MasteryPresentation.percentText(belief))
                                .font(.caption.weight(.semibold))
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
            .padding(Space.section)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
