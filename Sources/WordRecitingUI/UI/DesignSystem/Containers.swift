import SwiftUI
import WordRecitingCore

// MARK: - 容器组件
//
// @ai: 替换掉 41 处手写 `RoundedRectangle + background + overlay` 组合。
//      它们的问题不是「难看」，而是**层级不可读**：卡片和面板用了同样的底、
//      同样的圆角、差 2pt 的间距，于是用户分不清哪块是容器、哪块是内容。

// MARK: 卡片

/// 卡片：内容块的最小容器。
struct Card<Content: View>: View {
    var padding: CGFloat = Space.l
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: .rect(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(Surface.separator, lineWidth: Stroke.hairline)
            )
    }
}

// MARK: 面板

/// 面板：比卡片更轻的容器（用于侧栏区块、配置分组）。
struct Panel<Content: View>: View {
    var padding: CGFloat = Space.l
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.panel, in: .rect(cornerRadius: Radius.control))
    }
}

// MARK: 区块

/// 区块：标题 + 可选说明 + 内容。
/// @ai: 替代 34 处「`.font(.headline)` 手写标题 + VStack」的重复。
///      统一后所有页面的区块节奏一致：标题 15pt 半粗、说明 12pt 次要色、
///      标题与内容间距 8pt。
struct Section<Content: View>: View {
    let title: String
    var note: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sectionTitle) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(title).font(Type.section)
                if let note {
                    Text(note)
                        .font(Type.caption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let trailing { trailing }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 页面骨架

/// 页面骨架：顶部工具条（`Surface.toolbar` 底）+ 弹性内容区，**并统一内容区边距**。
///
/// @ai: 工具条那套 `.padding(.horizontal).padding(.vertical).background(.bar)` 在 8 个
///      页面逐字重复，这里收成一处。
///
///      内容区边距也必须由这里给：以前各页自己写 `.padding(Space.page)` /
///      `Space.xxl` / `Space.section` / `Space.m` 四种不同值，同一层级的留白对不上，
///      这是「各种边距」的直接来源。现在默认 `Space.page` + 区块间距 `Space.section`；
///      **只有真正需要通栏的内容**（贴边列表、满宽图表）才传 `contentPadding: 0`
///      并在内部自行处理——不要为了局部对齐而在页面里再叠一层 padding。
struct PageScaffold<Toolbar: View, Content: View>: View {
    var toolbarLeading: CGFloat = Space.toolbarH
    /// 内容区统一边距（四边）。通栏内容传 0。
    var contentPadding: CGFloat = Space.page
    /// 内容区自上而下的区块间距。
    var contentSpacing: CGFloat = Space.section
    /// 是否由骨架提供滚动。分栏页（左列表 + 右详情）传 false，各栏自己滚。
    var scrolls: Bool = true
    @ViewBuilder let toolbar: () -> Toolbar
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                toolbar()
            }
            .padding(.horizontal, toolbarLeading)
            .padding(.vertical, Space.toolbarV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.toolbar)
            Rule()
            if scrolls {
                ScrollView {
                    body(padded: true)
                }
            } else {
                body(padded: false)
            }
        }
    }

    @ViewBuilder
    private func body(padded: Bool) -> some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            content()
        }
        .padding(padded ? contentPadding : 0)
        .frame(maxWidth: .infinity, maxHeight: scrolls ? nil : .infinity,
               alignment: .topLeading)
    }
}

/// 无工具条的页面骨架（内容直接铺满）。
struct PageBody<Content: View>: View {
    var padding: CGFloat = Space.page
    var spacing: CGFloat = Space.section
    var scrolls: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: spacing) {
                        content()
                    }
                    .padding(padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: spacing) {
                    content()
                }
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: 分栏

/// 固定左栏 + 弹性右栏。
/// @ai: **禁用 HSplitView**（macOS 27 beta 拖分栏会触发 FocusBridge key-view-loop 崩溃，
///      见 docs/superpowers/specs/2026-08-11-ui-redesign-design.md）。
///      这个组件就是那套「固定宽 + Divider + 弹性」的安全写法，统一到这里。
struct SplitPane<Leading: View, Trailing: View>: View {
    let leadingWidth: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading()
                .frame(width: leadingWidth)
            Rule(axis: .vertical)
            trailing()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: 列表行

/// 列表行：hover 反馈 + 选中态 + 统一内边距。
/// @ai: 替代各页手写的 row + `.contentShape(Rectangle())` + 背景判断。
///      旧实现里选中色有 `accentColor.opacity(0.12)` 和 `0.15` 两种，hover 有的页面没有。
struct ListRow<Content: View>: View {
    var selected: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
    }

    private var row: some View {
        content()
            .padding(.horizontal, Space.rowH)
            .padding(.vertical, Space.rowV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
            .onHover { hovering = action != nil && $0 }
    }

    private var background: Color {
        if selected { return Surface.rowSelected }
        if hovering { return Surface.rowHover }
        return .clear
    }
}

// MARK: 空状态

/// 空状态：图标 + 标题 + 说明 + 可选操作。
/// @ai: 原来 14 份各写一遍，图标大小在 32/36/46/48 之间乱跳。
///      这里统一 32pt 图标、13pt 标题、12pt 说明，居中且最大宽 360（避免长句糊满整行）。
struct EmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Ink.tertiary)
            Text(title)
                .font(Type.emphasis)
                .foregroundStyle(Ink.primary)
            if let message {
                Text(message)
                    .font(Type.caption)
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxl)
    }
}
