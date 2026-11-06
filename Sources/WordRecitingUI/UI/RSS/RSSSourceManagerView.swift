import SwiftUI
import WordRecitingCore

/// RSS 源管理（数据区「RSS 源」子区，spec §4.1）：内置 + 自定义源列表，增删管理。
/// 阅读文章在「阅读」子区（ReadingView）；这里只负责源配置。
///
/// @ai: 不用 `List`（macOS 27 beta 拖分栏会触发 FocusBridge key-view-loop 崩溃），
///      列表用 `ScrollView + LazyVStack`。
///      结构全部走设计系统：工具条 `PageScaffold`、分行 `ListRow`、空态 `EmptyState`、
///      按钮 `DButton`/`IconButton`——**不要再手写 padding / 圆角 / 按钮样式**。
public struct RSSSourceManagerView: View {
    @State private var store = RSSSourceStore.shared
    @State private var showAddSource = false

    public init() {}

    public var body: some View {
        PageScaffold {
            Text("管理阅读来源，内置不可删，自定义可随时移除。")
                .font(Type.caption)
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: Space.m)
            DButton("添加自定义源", rank: .secondary, icon: "plus") {
                showAddSource = true
            }
        } content: {
            sourceList
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceForm { title, urlString in
                store.addCustom(title: title, urlString: urlString)
            }
        }
    }

    // MARK: - 源列表

    private var sourceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                groupHeader(
                    "内置源",
                    count: RSSSourceStore.builtIn.count,
                    note: "来自内置目录，不可移除")
                ForEach(RSSSourceStore.builtIn) { source in
                    sourceRow(source, removable: false)
                }

                groupHeader("自定义源", count: store.custom.count, note: nil)
                if store.custom.isEmpty {
                    EmptyState(
                        icon: "dot.radiowaves.left.and.right",
                        title: "暂无自定义源",
                        message: "点击右上角「添加自定义源」，填入标题与 RSS 地址即可。")
                        .frame(height: 160)
                } else {
                    ForEach(store.custom) { source in
                        sourceRow(source, removable: true)
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.page)
        }
    }

    private func groupHeader(_ title: String, count: Int, note: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.s) {
                Text(title).font(Type.section)
                Chip(text: "\(count)", tint: Ink.secondary)
                Spacer(minLength: 0)
            }
            if let note {
                Text(note).font(Type.micro).foregroundStyle(Ink.tertiary)
            }
        }
        .padding(.top, Space.l)
        .padding(.bottom, Space.s)
    }

    private func sourceRow(_ source: RSSSource, removable: Bool) -> some View {
        VStack(spacing: 0) {
            ListRow {
                HStack(spacing: Space.m) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(IconSize.control)
                        .foregroundStyle(Ink.secondary)
                        .frame(width: Size.iconTiny)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(source.title)
                            .font(Type.emphasis)
                            .foregroundStyle(Ink.primary)
                        Text(source.urlString)
                            .font(Type.micro)
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.m)
                    if removable {
                        IconButton(icon: "trash", help: "删除该源", tint: .red) {
                            store.remove(source.id)
                        }
                    } else {
                        Chip(text: "内置", tint: Ink.tertiary)
                    }
                }
            }
            Rule()
        }
    }
}
