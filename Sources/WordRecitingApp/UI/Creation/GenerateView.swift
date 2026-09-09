import SwiftUI

/// 造文主界面（spec §4.2 创作）：Finder 式横向多列——主题 | 生成方式 | 选词器 | 生成过程 | 文章；
/// 历史为右侧 overlay 抽屉。列宽先固定档位跑通，拖拽调宽后续任务验证。
/// @ai: 主路径视图；不写 SQL；生成走 vm.runGenerate() → World.run(ContentGenSystem)。
struct GenerateView: View {
    @State var vm: GenerateViewModel
    /// 左侧导航栏总宽（一级折叠宽 + 二级宽）：横向滚动容器首项占位，初始时第一列起始于导航栏右侧。
    let navLeadingWidth: CGFloat
    /// 顶部安全区高度（标题栏带）：列头从安全区下沿开始，不被标题栏盖住。
    let topInset: CGFloat
    @State var showAdvisor = false
    @State var tappedToken: ArticleWordToken?
    /// 列3 选词器展开状态（可收起）。
    @State var showPicker = true
    /// 右侧生成历史（抽屉）展开状态。
    @State var showHistory = true

    init(world: World, navLeadingWidth: CGFloat, topInset: CGFloat) {
        self.navLeadingWidth = navLeadingWidth
        self.topInset = topInset
        _vm = State(initialValue: GenerateViewModel(world: world))
    }

    var body: some View {
        // Finder 多列：外层横向滚动容器，每列固定宽、内部竖向滚动；
        // 列1 主题 / 列2 生成方式 / 列3 选词器（可收起）/ 列4 生成过程 / 列5 文章
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                // 首项占位：初始时第一列起始于导航栏右侧；
                // 横向滚动时列内容可滚入导航栏下，被其材质模糊（Finder 式）
                Color.clear
                    .frame(width: navLeadingWidth)
                topicColumn
                Divider()
                configColumn
                Divider()
                if showPicker {
                    pickerColumn
                    Divider()
                }
                processColumn
                Divider()
                articleColumn
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            // 列头从标题栏安全区下沿开始（content 延伸到顶，需手动下移）
            .padding(.top, topInset)
        }
        // 横向滚动条起点右移 navLeadingWidth：滚动条不出现在导航栏区域下
        .contentMargins(.leading, navLeadingWidth, for: .scrollIndicators)
        .overlay(alignment: .trailing) {
            if showHistory {
                historyDrawer.transition(.move(edge: .trailing))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showPicker)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showHistory)
        // 裁剪到内容区边界：右侧抽屉滑入/滑出动画不会盖到左侧全局导航栏
        .clipped()
        .onAppear {
            vm.loadDecks()
            vm.loadHistory()
        }
    }

    // MARK: - 列5：文章（flex 最宽）

    private var articleColumn: some View {
        ColumnShell(title: "文章", trailing: {
            if let article = vm.resultArticle, !article.spans.isEmpty {
                Text("\(article.spans.count) 个目标词")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { showPicker.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(showPicker ? "收起选词器列" : "展开选词器列")
            Button { showHistory.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(showHistory ? "收起生成历史" : "展开生成历史")
        }) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    if vm.isGenerating {
                        liveStreamView
                    } else if let article = vm.resultArticle {
                        articleFlow(body: article.body, spans: article.spans)
                    } else if let stored = vm.selectedArticle {
                        articleFlow(body: stored.body, spans: stored.spans)
                    } else {
                        Text("输入主题并选择目标词后，点击「生成文章」。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
                legend
            }
            .padding(16)
        }
        // 横向滚动模式下列宽固定（Finder 式）：文章列为阅读舒适宽度
        .frame(width: 640)
        .frame(maxHeight: .infinity, alignment: .top)
        .popover(item: $tappedToken, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { token in
            readingPopover(token)
        }
    }

    /// 生成过程中的实时流式输出：随输出实时解析目标词并高亮（与完成后的阅读区同款渲染）。
    @ViewBuilder
    private var liveStreamView: some View {
        if vm.streamedText.isEmpty {
            Text("正在生成…")
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } else {
            articleFlow(body: vm.streamedText, spans: vm.liveSpans)
        }
    }

    /// 阅读区图例：目标词 + 掌握度状态色（全词可点）。
    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Color.orange).frame(width: 10, height: 10)
                Text("目标词 · 点看释义")
                    .font(.caption2)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Color.green).frame(width: 10, height: 10)
                Text("已会")
                    .font(.caption2)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Color.red).frame(width: 10, height: 10)
                Text("不会")
                    .font(.caption2)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Color.blue).frame(width: 10, height: 10)
                Text("出现过")
                    .font(.caption2)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.4)).frame(width: 10, height: 10)
                Text("未见 · 点击标记")
                    .font(.caption2)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 右：历史（overlay 抽屉）

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
}

// MARK: - 目标词标签流式布局（已迁移到 ChipWall，见 UI/Components/ChipWall.swift）
