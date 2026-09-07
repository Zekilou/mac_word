import SwiftUI

/// 改写视图：左源文 + 目标词 + 快速改写按钮，中 diff 结果，右生成历史。
/// @ai: 不写 SQL；所有写通过 vm.runRewrite() → World.run(ContentGenSystem)。
struct RewriteView: View {
    @State private var vm: RewriteViewModel
    /// 左侧输入面板（侧栏）展开状态。
    @State private var showInput = true
    /// 右侧生成历史（侧栏）展开状态。
    @State private var showHistory = true

    init(world: World) {
        _vm = State(initialValue: RewriteViewModel(world: world))
    }

    var body: some View {
        // 抽屉式侧栏：overlay 覆盖在结果区上方滑入/滑出，不挤压主内容布局
        outputPane
            .overlay(alignment: .leading) {
                if showInput {
                    inputDrawer.transition(.move(edge: .leading))
                }
            }
            .overlay(alignment: .trailing) {
                if showHistory {
                    historyDrawer.transition(.move(edge: .trailing))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showInput)
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showHistory)
            // 裁剪到内容区边界：抽屉滑入/滑出动画不会盖到左侧全局导航栏
            .clipped()
            .onAppear { vm.loadHistory() }
    }

    // MARK: - 抽屉侧栏

    /// 左侧抽屉：输入设置（覆盖式滑入）。
    private var inputDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("输入设置").font(.headline)
                Spacer()
                Button { showInput = false } label: {
                    Image(systemName: "chevron.compact.left")
                }
                .buttonStyle(.borderless)
                .help("收起侧栏")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            inputPane
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.22), radius: 10, x: 4, y: 0)
    }

    /// 右侧抽屉：生成历史（覆盖式滑入）。
    private var historyDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("生成历史").font(.headline)
                Spacer()
                Button { vm.loadHistory() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新历史")
                Button { showHistory = false } label: {
                    Image(systemName: "chevron.compact.right")
                }
                .buttonStyle(.borderless)
                .help("收起侧栏")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.history) { item in
                        Button { vm.selectHistory(item.id) } label: {
                            historyCard(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.22), radius: 10, x: -4, y: 0)
    }

    // MARK: - 左：输入

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            generatorSelector
            labeled("源文") {
                editor(text: $vm.sourceText, minHeight: 180)
            }
            labeled("目标词（逗号 / 分号 / 换行分隔）") {
                editor(text: $vm.targetsText, minHeight: 70)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await vm.runRewrite() }
                } label: {
                    Label("AI 改写", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isGenerating)
                if vm.isGenerating { ProgressView().scaleEffect(0.7) }
                if let stage = vm.genStage {
                    Text(stage.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// 生成方式选择：档位 + （远端时）API 配置菜单 + 当前模型/端点说明。
    /// @ai: 与设置页共用 AppSettings；改动即时写回，生成前再 persist 一次保证一致。
    private var generatorSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("生成方式").font(.caption).foregroundStyle(.secondary)
            Picker("生成引擎", selection: Binding(
                get: { vm.generatorTier },
                set: { newTier in
                    vm.generatorTier = newTier
                    vm.persistSettings()
                }
            )) {
                ForEach(GeneratorTier.allCases) { tier in
                    Text(tier.rawValue).tag(tier)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if vm.generatorTier == .remote {
                apiConfigSelector
            } else {
                Text("进程内本地引擎：模型文件在「设置 → 模型 → 进程内模型」中选择后使用。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 远端档的 API 配置选择菜单（仅远程档展示）。
    private var apiConfigSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API 配置").font(.caption2).foregroundStyle(.tertiary)
            if vm.apiConfigs.isEmpty {
                Text("还没有 API 配置，去「设置 → 模型 → API 配置」添加。")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Picker("API 配置", selection: Binding(
                    get: { vm.activeAPIConfigID ?? vm.apiConfigs[0].id },
                    set: { id in
                        if let config = vm.apiConfigs.first(where: { $0.id == id }) {
                            vm.applyAPIConfig(config)
                        }
                    }
                )) {
                    ForEach(vm.apiConfigs) { config in
                        Text(config.name).tag(config.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("\(vm.llmModel) · \(vm.llmBaseURL)")
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    // MARK: - 中：diff 结果

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showInput.toggle() } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help(showInput ? "收起输入面板" : "展开输入面板")
                Text("改写结果").font(.headline)
                Spacer()
                if let article = vm.resultArticle, !article.spans.isEmpty {
                    Text("\(article.spans.count) 处替换")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { showHistory.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help(showHistory ? "收起生成历史" : "展开生成历史")
            }
            ScrollView {
                if let article = vm.resultArticle {
                    diffText(body: article.body, spans: article.spans)
                } else if let stored = vm.selectedArticle {
                    diffText(body: stored.body, spans: stored.spans)
                } else {
                    Text("点击「AI 改写」生成（按当前生成方式走 LLM）；或从右侧历史选择一篇回看。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            legend
        }
        .padding(16)
    }

    private func diffText(body: String, spans: [SpanInfo]) -> some View {
        Text(diffAttributedString(body: body, spans: spans))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("原词", color: .secondary, strike: true)
            legendItem("替换词", color: .accentColor, strike: false)
            legendItem("目标词", color: .orange, strike: false)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ text: String, color: Color, strike: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text).strikethrough(strike).foregroundStyle(color)
        }
    }

    // MARK: - 右：历史

    private func historyCard(_ item: ArticleHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.bodyPreview.isEmpty ? "(空)" : item.bodyPreview)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.primary)
            HStack {
                Text(item.generatorId).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(item.createdAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(vm.selectedArticle?.id == item.id ? Color.accentColor.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    // MARK: - 复用组件

    private func labeled<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .frame(minHeight: minHeight)
            .font(.body)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - diff AttributedString 构建

/// 把改写后的 body + spans 渲染成 inline diff AttributedString：
/// - 替换型 span：原词（删除线灰色）+ " → " + 新词（品牌色高亮）
/// - 直达目标词 span：黄色高亮
/// @ai: 偏移基于 body 字符索引；越界 span 安全跳过。
private func diffAttributedString(body: String, spans: [SpanInfo]) -> AttributedString {
    let chars = Array(body)
    var result = AttributedString()
    var cursor = 0
    for span in spans.sorted(by: { $0.start < $1.start }) {
        guard span.start >= cursor, span.start <= chars.count,
              span.end > span.start, span.end <= chars.count else { continue }
        if span.start > cursor {
            result += AttributedString(String(chars[cursor..<span.start]))
        }
        let surface = String(chars[span.start..<span.end])
        if let original = span.replacedFrom {
            var del = AttributedString(original)
            del.strikethroughStyle = .single
            del.foregroundColor = .secondary
            result += del
            var arrow = AttributedString(" → ")
            arrow.foregroundColor = .secondary
            result += arrow
            var rep = AttributedString(surface)
            rep.foregroundColor = .accentColor
            rep.backgroundColor = Color.accentColor.opacity(0.18)
            result += rep
        } else {
            var hi = AttributedString(surface)
            hi.foregroundColor = .orange
            hi.backgroundColor = Color.orange.opacity(0.18)
            result += hi
        }
        cursor = span.end
    }
    if cursor < chars.count {
        result += AttributedString(String(chars[cursor..<chars.count]))
    }
    return result
}
