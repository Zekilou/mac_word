import SwiftUI

/// 已记录词汇表：列出全局有记录的词（会/不会/出现过），筛选 + 搜索 + 掌握度/释义/来源。
/// @ai: 不用 List（macOS 27 beta 拖分栏崩溃规避），列表用 ScrollView + LazyVStack。
struct VocabularyListView: View {
    @State private var vm: VocabularyListViewModel

    init(world: World) {
        _vm = State(initialValue: VocabularyListViewModel(world: world))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            if vm.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    // MARK: - 顶栏：搜索 + 筛选 + 计数

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索词或释义", text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            .frame(maxWidth: 220)

            Picker("", selection: $vm.filter) {
                ForEach(VocabularyListViewModel.Filter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Picker("", selection: $vm.sortOrder) {
                ForEach(VocabularyListViewModel.SortOrder.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)
            .help("排序方式（阅读频次 = 读过的内容中累计出现次数）")

            Button { vm.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")

            Spacer()
            Text(countsText).font(.callout).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var countsText: String {
        let c = vm.countByState
        return "会 \(c.known) · 不会 \(c.unknown) · 学习中 \(c.learning) · 出现过 \(c.seen) · 共 \(vm.entries.count)"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("还没有词汇记录").font(.headline)
            Text("在「初始化段落」标记词汇，或阅读 RSS 文章后，这里会列出所有有记录的词。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.filtered) { entry in
                    row(entry)
                    Divider().padding(.leading, 12)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ e: GraphQueries.RecordedLemma) -> some View {
        let state = WordMarkState.from(
            mastery: e.mastery > 0 ? e.mastery : nil,
            seenCount: e.seenCount)
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(state.color).frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(vm.displayText(e))
                        .font(.body.weight(.semibold))
                    Text(state.label).font(.caption).foregroundStyle(.secondary)
                    if let src = e.source {
                        Text("来源 \(src)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if e.mastery > 0 {
                        Text(String(format: "%.1f", e.mastery))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    // 阅读频次：读过的内容中累计出现次数（RSS 等自动累计）
                    HStack(spacing: 3) {
                        Image(systemName: "eye")
                        Text("\(e.seenCount) 次")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("阅读频次：在已读文章/段落中累计出现 \(e.seenCount) 次")
                }
                if let def = e.definition, !def.isEmpty {
                    Text(def).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
