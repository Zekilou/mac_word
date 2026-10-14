import SwiftUI

/// 同义词管理视图：左添加面板（两搜索框+候选+添加按钮），右映射列表。
/// @ai: 严格贴合 user_profile：紧凑 UI、重要按钮在显眼位置。
struct SynonymManagerView: View {
    let world: World
    @State private var viewModel: SynonymManagerViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
            } else {
                ProgressView().onAppear {
                    viewModel = SynonymManagerViewModel(world: world)
                    viewModel?.onAppear()
                }
            }
        }
    }

    private func content(vm: SynonymManagerViewModel) -> some View {
        // @ai: 禁用 HSplitView（macOS 27 beta 拖分栏崩溃，见 ui-redesign-design.md）。
        //      固定宽左面板 + Divider + 弹性右列表（与 ReadingView 一致）。
        HStack(spacing: 0) {
            // 左：添加面板
            addPanel(vm: vm)
                .frame(width: 380)
            Divider()
            // 右：映射列表
            mappingList(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 左面板：添加同义词

    private func addPanel(vm: SynonymManagerViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加同义词映射").font(.headline)

            // 源词
            VStack(alignment: .leading, spacing: 4) {
                Text("源词（要被替换的词）").font(.caption).foregroundStyle(.secondary)
                TextField("输入单词前缀搜索，例：aban", text: bind(vm, \.fromSearchText))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vm.fromSearchText) { _, _ in vm.updateFromCandidates() }
                candidateList(
                    items: vm.fromCandidates,
                    selected: Binding(
                        get: { vm.selectedFrom },
                        set: { vm.selectedFrom = $0 }),
                    searchText: vm.fromSearchText,
                    emptyWhenSelected: {
                        if let s = vm.selectedFrom { vm.fromSearchText = s.text }
                        vm.fromCandidates = []
                    })
            }

            Image(systemName: "arrow.down")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            // 同义词
            VStack(alignment: .leading, spacing: 4) {
                Text("同义词（替换后的词）").font(.caption).foregroundStyle(.secondary)
                TextField("输入单词前缀搜索，例：fors", text: bind(vm, \.toSearchText))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vm.toSearchText) { _, _ in vm.updateToCandidates() }
                candidateList(
                    items: vm.toCandidates,
                    selected: Binding(
                        get: { vm.selectedTo },
                        set: { vm.selectedTo = $0 }),
                    searchText: vm.toSearchText,
                    emptyWhenSelected: {
                        if let s = vm.selectedTo { vm.toSearchText = s.text }
                        vm.toCandidates = []
                    })
            }

            // 选中预览
            if let f = vm.selectedFrom, let t = vm.selectedTo {
                HStack(spacing: 8) {
                    tagView(f.text, color: .accentColor)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    tagView(t.text, color: .green)
                }
                .padding(.top, 4)
            }

            Button(action: { vm.addMapping() }) {
                Label("添加映射", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canAdd())

            Spacer(minLength: 0)
        }
        .padding(16)
        .overlay(alignment: .top) { messageBanners(vm) }
    }

    private func candidateList(
        items: [LemmaCandidate],
        selected: Binding<LemmaCandidate?>,
        searchText: String,
        emptyWhenSelected: @escaping () -> Void
    ) -> some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return AnyView(EmptyView()) }
        if items.isEmpty {
            return AnyView(
                Text("未找到匹配的单词，请先从词库导入").font(.caption).foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            )
        }
        return AnyView(
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { cand in
                        Button(action: {
                            selected.wrappedValue = cand
                            emptyWhenSelected()
                        }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cand.text).fontWeight(.medium)
                                if let def = cand.definition, !def.isEmpty {
                                    Text(def).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected.wrappedValue?.lemmaId == cand.lemmaId
                                        ? Color.accentColor.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 140)
            .padding(4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        )
    }

    // MARK: - 右面板：映射列表

    private func mappingList(vm: SynonymManagerViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("已定义同义词（\(vm.mappings.count)）").font(.subheadline).fontWeight(.medium)
                Spacer()
                Button(action: { vm.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if vm.mappings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("尚未定义同义词映射").foregroundStyle(.secondary)
                    Text("在左侧选择源词和同义词，点击「添加映射」开始")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // @ai: 不用 List（NSTableView），避免 macOS 27 FocusBridge 布局时 key view loop 崩溃
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.mappings) { m in
                            mappingRow(m, vm: vm)
                        }
                    }
                }
            }
        }
    }

    private func mappingRow(_ m: SynonymMapping, vm: SynonymManagerViewModel) -> some View {
        HStack(spacing: 12) {
            // 删除按钮（重要操作在第一列）
            Button(action: { vm.remove(mapping: m) }) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("删除此映射")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    tagView(m.fromText, color: .accentColor)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    tagView(m.toText, color: .green)
                }
                HStack(spacing: 8) {
                    Text(m.sourceType).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(String(format: "权重 %.2f", m.weight))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(m.createdAt, format: .dateTime.month().day().year())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - 公共 UI

    private func tagView(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func messageBanners(_ vm: SynonymManagerViewModel) -> some View {
        VStack(spacing: 4) {
            if let err = vm.errorMessage {
                banner(text: err, color: .red)
            }
            if let ok = vm.lastSuccessMessage {
                banner(text: ok, color: .green)
            }
        }
        .padding(.top, 2)
    }

    private func banner(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // 辅助：@Observable 与 SwiftUI Binding 桥接
    private func bind<T>(_ vm: SynonymManagerViewModel, _ keyPath: ReferenceWritableKeyPath<SynonymManagerViewModel, T>) -> Binding<T> {
        Binding(
            get: { vm[keyPath: keyPath] },
            set: { vm[keyPath: keyPath] = $0 }
        )
    }
}
