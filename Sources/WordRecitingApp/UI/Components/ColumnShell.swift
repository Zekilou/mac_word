import SwiftUI

/// 列壳（L2 复合组件）：标题头（.bar 材质）+ 弹性内容区 + 底部操作区（footer）。
/// 内容撑满剩余高度（随窗口伸缩）；footer 固定底部（sticky），放主操作按钮。
struct ColumnShell<Trailing: View, Content: View, Footer: View>: View {
    let title: String
    private let trailing: Trailing
    private let content: Content
    private let footer: Footer
    private let hasFooter: Bool

    init(
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
        self.footer = footer()
        self.hasFooter = Footer.self != EmptyView.self
    }

    /// 无 trailing / footer 的快捷 init。
    init(title: String, @ViewBuilder content: () -> Content)
        where Trailing == EmptyView, Footer == EmptyView {
        self.init(title: title, trailing: { EmptyView() }, content: content, footer: { EmptyView() })
    }

    /// 仅有 trailing（收起按钮等）。
    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content)
        where Footer == EmptyView {
        self.init(title: title, trailing: trailing, content: content, footer: { EmptyView() })
    }

    /// 仅有 footer（底部操作区）。
    init(title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer)
        where Trailing == EmptyView {
        self.init(title: title, trailing: { EmptyView() }, content: content, footer: footer)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if hasFooter {
                Divider()
                footer
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
