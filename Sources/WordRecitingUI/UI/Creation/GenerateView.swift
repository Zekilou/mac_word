import SwiftUI
import WordRecitingCore

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
                Rule()
                configColumn
                Rule()
                if showPicker {
                    pickerColumn
                    Rule()
                }
                processColumn
                Rule()
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
                    .font(Type.caption).foregroundStyle(Ink.secondary)
            }
            IconButton(icon: "sidebar.left",
                       help: showPicker ? "收起选词器列" : "展开选词器列") {
                showPicker.toggle()
            }
            IconButton(icon: "sidebar.right",
                       help: showHistory ? "收起生成历史" : "展开生成历史") {
                showHistory.toggle()
            }
        }) {
            VStack(alignment: .leading, spacing: Space.m) {
                ScrollView {
                    if vm.isGenerating {
                        liveStreamView
                    } else if let article = vm.resultArticle {
                        articleFlow(body: article.body, spans: article.spans)
                    } else if let stored = vm.selectedArticle {
                        articleFlow(body: stored.body, spans: stored.spans)
                    } else {
                        Text("输入主题并选择目标词后，点击「生成文章」。")
                            .foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.m)
                    }
                }
                legend
            }
            .padding(Space.page)
        }
        // 横向滚动模式下列宽固定（Finder 式）：文章列为阅读舒适宽度
        .frame(width: Size.articleMax)
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
                .font(Type.body)
                .foregroundStyle(Ink.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.m)
        } else {
            articleFlow(body: vm.streamedText, spans: vm.liveSpans)
        }
    }

    /// 阅读区图例：目标词 + 掌握度状态色（全词可点）。
    private var legend: some View {
        HStack(spacing: Space.m) {
            HStack(spacing: Space.xs) {
                RoundedRectangle(cornerRadius: Radius.chip).fill(Color.orange).frame(width: Size.cellTiny, height: Size.cellTiny)
                Text("目标词 · 点看释义")
                    .font(Type.micro)
            }
            HStack(spacing: Space.xs) {
                RoundedRectangle(cornerRadius: Radius.chip).fill(Color.green).frame(width: Size.cellTiny, height: Size.cellTiny)
                Text("已会")
                    .font(Type.micro)
            }
            HStack(spacing: Space.xs) {
                RoundedRectangle(cornerRadius: Radius.chip).fill(Color.red).frame(width: Size.cellTiny, height: Size.cellTiny)
                Text("不会")
                    .font(Type.micro)
            }
            HStack(spacing: Space.xs) {
                RoundedRectangle(cornerRadius: Radius.chip).fill(Color.blue).frame(width: Size.cellTiny, height: Size.cellTiny)
                Text("出现过")
                    .font(Type.micro)
            }
            HStack(spacing: Space.xs) {
                RoundedRectangle(cornerRadius: Radius.chip).fill(Color.gray.opacity(0.4)).frame(width: Size.cellTiny, height: Size.cellTiny)
                Text("未见 · 点击标记")
                    .font(Type.micro)
            }
            Spacer()
        }
        .foregroundStyle(Ink.secondary)
    }

    // MARK: - 右：历史（overlay 抽屉）

    private var historyDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Text("生成历史").font(Type.section)
                Spacer()
                IconButton(icon: "arrow.clockwise", help: "刷新历史") {
                    vm.loadHistory()
                }
                IconButton(icon: "chevron.compact.right", help: "收起侧栏") {
                    showHistory = false
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.toolbarV)
            Rule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(vm.history) { item in
                        historyCard(item)
                    }
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.m)
        }
        .frame(width: Size.panePreview)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.22), radius: 10, x: -4, y: 0)
    }

    private func historyCard(_ item: ArticleHistoryItem) -> some View {
        ListRow(selected: vm.selectedArticle?.id == item.id, action: { vm.selectHistory(item.id) }) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(item.bodyPreview.isEmpty ? "(空)" : item.bodyPreview)
                    .font(Type.caption)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                HStack {
                    Text(item.generatorId).font(Type.micro).foregroundStyle(Ink.secondary)
                    Spacer()
                    Text(item.createdAt, style: .date).font(Type.micro).foregroundStyle(Ink.tertiary)
                }
            }
        }
    }
}

// MARK: - 目标词标签流式布局（已迁移到 ChipWall，见 UI/Components/ChipWall.swift）
