import SwiftUI

/// 应用主壳：三分栏 —— 一级区（数据/学习/设置，可收折）| 二级子区 | 内容区。
/// @ai: 严格贴合 spec §3.2/§3.3：禁用原生标题栏、一级栏可折叠、二级联动当前区。
/// 顶部保留全局活动条（悬浮胶囊形态后续任务替换）。
struct ContentView: View {
    let world: World
    @State private var zoneCollapsed = false
    @State private var section: AppSection = .home

    /// 一级栏宽度（折叠时仅图标）。
    private var zoneWidth: CGFloat { zoneCollapsed ? 48 : 150 }
    /// 二级栏宽度：首页无二级子区 → 收折为 0。
    private var sectionWidth: CGFloat { section == .home ? 0 : 140 }
    /// 内容区左侧留白（一级 + 二级）。
    private var navWidth: CGFloat { zoneWidth + sectionWidth }

    var body: some View {
        // 最外层 GeometryReader 捕获真实顶部安全区高度（标题栏带高度），
        // 之后三分栏内容用它手动下移；若直接整体 ignoresSafeArea，这里读到 0。
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            ZStack(alignment: .topLeading) {
                // 内容层：占满全窗口（横向滚动内容可延伸到导航栏之下，被导航栏材质模糊）；
                // 首项偏移在内容内部处理（GenerateView 横向滚动容器第一列前占位）
                contentView(topInset: topInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                // 列间分割线（替代 HStack Divider，延伸至最顶）
                vSeparator(offset: zoneWidth)
                if sectionWidth > 0 {
                    vSeparator(offset: navWidth)
                }
                // 二级导航栏：背景条从窗口最左延伸到二级栏位置（一级宽+二级宽），内容在一级栏右侧
                sectionSidebar(topInset: topInset)
                // 左侧一级导航栏浮层：overlay 在二级导航栏之上（Finder 侧边栏质感）
                zoneSidebar(topInset: topInset)
                // 全局状态 = 左下角胶囊：圆角矩形，宽 < 一级折叠+二级导航栏总宽（188），多任务竖向堆叠
                ActivityCapsuleView(center: .shared)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 4)
                    .padding(.bottom, 4)
            }
            // 延伸至窗口最顶：栏体背景/分割线/内容背景进入标题栏带
            .ignoresSafeArea(edges: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 竖向分割线（全高，从窗口最顶开始）。
    private func vSeparator(offset: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .padding(.leading, offset)
    }

    private func zoneSidebar(topInset: CGFloat) -> some View {
        // 顶部不再显示软件名（系统标题栏已显示）与分割线：
        // 折叠按钮融入导航列表作首行，与二级首项同款同高，两栏顶部对齐。
        VStack(spacing: 2) {
            // 折叠控制：纯图标按钮（Apple 规范，SF Symbol + tooltip），无文字
            Button(action: { withAnimation { zoneCollapsed.toggle() } }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15))
                    .frame(width: 20)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: zoneCollapsed ? .center : .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收起 / 展开一级导航")
            ForEach(AppZone.allCases) { z in
                ZoneRowButton(
                    z: z,
                    selected: section.zone == z,
                    collapsed: zoneCollapsed
                ) {
                    if let first = AppSection.allCases.first(where: { $0.zone == z }) {
                        section = first
                    }
                }
            }
            // 吃满栏高，保证内容顶部对齐（与二级栏一致），不上下居中
            Spacer()
        }
        .padding(8)
        // 栏体延伸至顶，但内容从标题栏安全区下沿开始（topInset 由外层捕获，真实值）
        .padding(.top, max(topInset, 28))
        // 轻材质（.ultraThinMaterial）：overlay 浮在二级导航栏之上，模糊下层延伸内容
        .background(.ultraThinMaterial)
        // 一级浮在二级之上：右侧投影阴影区分层级
        .shadow(color: .black.opacity(0.16), radius: 5, x: 2, y: 0)
        .frame(width: zoneWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: zoneCollapsed)
    }

    // MARK: - 二级栏（当前一级的子区）

    /// 二级栏：背景条从窗口最左延伸到二级栏位置（一级宽+二级宽），
    /// 内容（子区导航项）位于一级栏右侧 140 宽内。
    /// @ai: 首页（`.home`）没有二级子区，`sectionWidth == 0` → 整栏不渲染。
    @ViewBuilder
    private func sectionSidebar(topInset: CGFloat) -> some View {
        if sectionWidth > 0 {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: zoneWidth)
                VStack(spacing: 2) {
                    ForEach(AppSection.allCases.filter { $0.zone == section.zone }) { s in
                        SectionRowButton(s: s, selected: section == s) {
                            section = s
                        }
                    }
                    Spacer()
                }
                .padding(8)
                .frame(width: sectionWidth)
            }
            .padding(.top, max(topInset, 28))
            // 轻材质背景：从窗口最左延伸到二级栏位置
            .background(.ultraThinMaterial)
            .frame(width: navWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - 内容区

    /// 内容区：创作页占满全窗（内部横向滚动首项占位 + 模糊）；
    /// 其余页面由 `appColumn` 统一包成「列」（ColumnShell 标题头 + 内容）——
    /// 内容从导航栏结束处开始、位于标题头下方，不再贴顶。
    @ViewBuilder
    private func contentView(topInset: CGFloat) -> some View {
        let navWidth = self.navWidth
        switch section {
        case .home: appColumn("首页", navWidth, topInset) {
            HomeView(world: world) { section = $0 }
        }
        case .creation: CreationView(world: world, navLeadingWidth: navWidth, topInset: topInset)
        case .decks: appColumn("词库", navWidth, topInset) { DeckManagerView(world: world) }
        case .vocabulary: appColumn("词汇", navWidth, topInset) { VocabularyInitView(world: world) }
        case .synonyms: appColumn("同义词", navWidth, topInset) { SynonymManagerView(world: world) }
        case .rssSources: appColumn("RSS 源", navWidth, topInset) { RSSSourceManagerView() }
        case .analytics: appColumn("分析", navWidth, topInset) { AnalyticsView(world: world) }
        case .dictionary: appColumn("词典", navWidth, topInset) { SystemDictionaryView(world: world) }
        case .reading: appColumn("阅读", navWidth, topInset) { ReadingView(world: world) }
        case .study: appColumn("背诵", navWidth, topInset) { StudyView(world: world) }
        case .model: appColumn("模型", navWidth, topInset) { SettingsView() }
        case .general: appColumn("通用", navWidth, topInset) { GeneralSettingsView() }
        case .storage: appColumn("储存", navWidth, topInset) { StorageSettingsView(world: world) }
        case .display: appColumn("显示", navWidth, topInset) { DisplaySettingsView() }
        }
    }

    /// 页面列壳：内容从导航栏结束处开始、列头从安全区下沿开始。
    /// @ai: 新增页面必须用它包裹，禁止自己算 navWidth / topInset。
    private func appColumn<Content: View>(
        _ title: String, _ navWidth: CGFloat, _ topInset: CGFloat,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: navWidth)
            ColumnShell(title: title) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 一级区导航行

/// 一级区按钮：hover 反馈 + 选中高亮；折叠时仅图标居中。
/// @ai: 不用 List（NSTableView 崩溃规避），自绘保证视觉一致。
private struct ZoneRowButton: View {
    let z: AppZone
    let selected: Bool
    let collapsed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: z.icon)
                    .font(.system(size: 15))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                if !collapsed {
                    Text(z.rawValue)
                        .font(.system(size: 13))
                    Spacer()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(z.rawValue)
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.18) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

// MARK: - 二级子区导航行

/// 二级子区按钮：与一级同款行样式（spec §3.2）。
private struct SectionRowButton: View {
    let s: AppSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: s.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(s.rawValue)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(s.rawValue)
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.15) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

// MARK: - 占位页

/// 通用子区占位页（期 1 骨架，后续任务逐个替换为真实页面）。
/// 注：当前已无任何调用（阅读/设置等子区均已被真实页面替换），保留作为通用占位组件。
struct PlaceholderPage: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("\(title)（待实现）")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
