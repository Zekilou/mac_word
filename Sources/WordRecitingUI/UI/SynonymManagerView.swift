import SwiftUI
import WordRecitingCore

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

    /// @ai: 左右分栏页 → `PageScaffold(scrolls: false)`：骨架只给顶部工具条，
    ///      **不**包滚动、**不**加内容区边距，各栏自己滚、自己处理边缘留白。
    ///      分栏本身走 `SplitPane`（禁用 HSplitView 的等价安全写法），不再手写
    ///      「HStack + 固定宽 + Rule + 弹性宽」。
    private func content(vm: SynonymManagerViewModel) -> some View {
        PageScaffold(scrolls: false) {
            Text("已定义同义词（\(vm.mappings.count)）").font(Type.section)
            Spacer(minLength: Space.m)
            IconButton(icon: "arrow.clockwise", help: "刷新") { vm.reload() }
        } content: {
            SplitPane(leadingWidth: Size.sidebarPanel) {
                // 左：添加面板
                addPanel(vm: vm)
            } trailing: {
                // 右：映射列表
                mappingList(vm: vm)
            }
        }
    }

    // MARK: - 左面板：添加同义词

    private func addPanel(vm: SynonymManagerViewModel) -> some View {
        Section(title: "添加同义词映射") {
            VStack(alignment: .leading, spacing: Space.l) {
            // 源词
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("源词（要被替换的词）").font(Type.caption).foregroundStyle(Ink.secondary)
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
                .foregroundStyle(Ink.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            // 同义词
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("同义词（替换后的词）").font(Type.caption).foregroundStyle(Ink.secondary)
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
                HStack(spacing: Space.m) {
                    tagView(f.text, color: .accentColor)
                    Image(systemName: "arrow.right").foregroundStyle(Ink.secondary)
                    tagView(t.text, color: .green)
                }
                .padding(.top, Space.xs)
            }

            DButton("添加映射", rank: .primary, icon: "plus.circle.fill",
                    fullWidth: true, disabled: !vm.canAdd()) {
                vm.addMapping()
            }

            Spacer(minLength: 0)
            }
        }
        .padding(Space.page)
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
                Text("未找到匹配的单词，请先从词库导入").font(Type.caption).foregroundStyle(Ink.tertiary)
                    .padding(.vertical, Space.xs)
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
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(cand.text).font(Type.bodyMedium)
                                if let def = cand.definition, !def.isEmpty {
                                    Text(def).font(Type.micro).foregroundStyle(Ink.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, Space.s)
                            .padding(.horizontal, Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected.wrappedValue?.lemmaId == cand.lemmaId
                                        ? Color.accentColor.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 140)
            .padding(Space.xs)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
        )
    }

    // MARK: - 右面板：映射列表

    /// 右栏：映射列表。
    /// @ai: 栏头（标题 + 刷新）已上移到页面骨架的工具条，这里只留列表本体，
    ///      左边缘与工具条标题对齐（Space.page）；滚动仍由本栏自己提供。
    private func mappingList(vm: SynonymManagerViewModel) -> some View {
        Group {
            if vm.mappings.isEmpty {
                EmptyState(
                    icon: "arrow.left.arrow.right",
                    title: "尚未定义同义词映射",
                    message: "在左侧选择源词和同义词，点击「添加映射」开始")
            } else {
                // @ai: 不用 List（NSTableView），避免 macOS 27 FocusBridge 布局时 key view loop 崩溃
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.mappings) { m in
                            mappingRow(m, vm: vm)
                        }
                    }
                    .padding(.horizontal, Space.page)
                    .padding(.vertical, Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mappingRow(_ m: SynonymMapping, vm: SynonymManagerViewModel) -> some View {
        HStack(spacing: Space.l) {
            // 删除按钮（重要操作在第一列）
            IconButton(icon: "trash", help: "删除此映射", tint: .red) { vm.remove(mapping: m) }

            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.m) {
                    tagView(m.fromText, color: .accentColor)
                    Image(systemName: "arrow.right").foregroundStyle(Ink.secondary)
                    tagView(m.toText, color: .green)
                }
                HStack(spacing: Space.m) {
                    Text(m.sourceType).font(Type.micro)
                        .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                    Text(String(format: "权重 %.2f", m.weight))
                        .font(Type.micro).foregroundStyle(Ink.secondary)
                    Text(m.createdAt, format: .dateTime.month().day().year())
                        .font(Type.micro).foregroundStyle(Ink.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, Space.xs)
    }

    // MARK: - 公共 UI

    private func tagView(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Type.caption)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
    }

    private func messageBanners(_ vm: SynonymManagerViewModel) -> some View {
        VStack(spacing: Space.xs) {
            if let err = vm.errorMessage {
                banner(text: err, color: .red)
            }
            if let ok = vm.lastSuccessMessage {
                banner(text: ok, color: .green)
            }
        }
        .padding(.top, Space.xxs)
    }

    private func banner(text: String, color: Color) -> some View {
        Text(text)
            .font(Type.caption)
            .foregroundStyle(color)
            .padding(.horizontal, Space.rowH).padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
    }

    // 辅助：@Observable 与 SwiftUI Binding 桥接
    private func bind<T>(_ vm: SynonymManagerViewModel, _ keyPath: ReferenceWritableKeyPath<SynonymManagerViewModel, T>) -> Binding<T> {
        Binding(
            get: { vm[keyPath: keyPath] },
            set: { vm[keyPath: keyPath] = $0 }
        )
    }
}
