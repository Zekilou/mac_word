import SwiftUI

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
            Divider()
            resultArea(vm)
        }
    }

    private func searchBar(_ vm: SystemDictionaryViewModel) -> some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func resultArea(_ vm: SystemDictionaryViewModel) -> some View {
        switch vm.phase {
        case .idle:
            emptyHint("输入单词后从 macOS 系统词典查询英英释义（懒加载，按词查询）")
        case .looking:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在查询「\(vm.lastQuery)」…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound(let word):
            emptyHint("系统词典中未找到「\(word)」")
        case .found(let entry):
            entryCard(entry, vm: vm)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func entryCard(_ entry: DictionaryEntry, vm: SystemDictionaryViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 词头 + 标记
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.word)
                            .font(.system(size: 28, weight: .bold))
                        HStack(spacing: 8) {
                            if let phonetic = entry.phonetic {
                                Text(phonetic).font(.title3).foregroundStyle(.secondary)
                            }
                            if let pos = entry.partOfSpeech {
                                Text(pos)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
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
                    .help("当前状态：\(vm.wordState.label)。点击切换 会/不会（写入全局掌握度）")
                }
                // 释义全文
                Text(entry.definition)
                    .font(.body)
                    .textSelection(.enabled)
                Divider()
                Text("数据来源：macOS 系统词典（Dictionary Services）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
