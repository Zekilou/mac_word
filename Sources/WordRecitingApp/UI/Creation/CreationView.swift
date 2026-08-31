import SwiftUI

/// 创作视图（主路径）：造文 / 改写 两个 Tab。
/// - 造文：用户给主题 + 目标词 → 自动生成含目标词的文章（默认，主路径）
/// - 改写：粘贴现有文章 → 同义词替换（次要路径）
struct CreationView: View {
    let world: World
    /// 左侧导航栏总宽（一级折叠宽 + 二级宽）：透传给造文页作为横向滚动首项占位。
    let navLeadingWidth: CGFloat
    /// 顶部安全区高度（标题栏带）：透传给造文页，列头从安全区下沿开始。
    let topInset: CGFloat
    @State private var tab: CreationTab = .generate

    enum CreationTab: String, CaseIterable, Identifiable {
        case generate = "造文"
        case rewrite = "改写"
        var id: String { rawValue }
    }

    init(world: World, navLeadingWidth: CGFloat, topInset: CGFloat) {
        self.world = world
        self.navLeadingWidth = navLeadingWidth
        self.topInset = topInset
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(CreationTab.allCases) { t in
                tabButton(t)
            }
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.vertical, 4)
    }

    private func tabButton(_ t: CreationTab) -> some View {
        Button {
            tab = t
        } label: {
            Text(t.rawValue)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(tab == t ? .primary : .secondary)
                .background(tab == t ? Color.accentColor.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .generate: GenerateView(world: world, navLeadingWidth: navLeadingWidth, topInset: topInset)
        case .rewrite: RewriteView(world: world)
        }
    }
}
