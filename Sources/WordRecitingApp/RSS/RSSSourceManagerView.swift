import SwiftUI

/// RSS 源管理（数据区「RSS 源」子区，spec §4.1）：内置 + 自定义源列表，增删管理。
/// 阅读文章在「阅读」子区（ReadingView）；这里只负责源配置。
/// @ai: 不用 List（macOS 27 beta 拖分栏崩溃规避），列表用 ScrollView + LazyVStack。
struct RSSSourceManagerView: View {
    @State private var store = RSSSourceStore.shared
    @State private var showAddSource = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            sourceList
        }
        .sheet(isPresented: $showAddSource) { addSourceSheet }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("管理阅读来源，内置不可删，自定义可随时移除。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                showAddSource = true
            } label: {
                Label("添加自定义源", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
    }

    // MARK: - 源列表

    private var sourceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Text("内置源（\(RSSSourceStore.builtIn.count)）")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(RSSSourceStore.builtIn) { source in
                    sourceRow(source, removable: false)
                }

                Text("自定义源（\(store.custom.count)）")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 12)
                if store.custom.isEmpty {
                    Text("暂无自定义源，点击右上角「添加自定义源」。")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(store.custom) { source in
                        sourceRow(source, removable: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func sourceRow(_ source: RSSSource, removable: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.callout)
                Text(source.urlString)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if removable {
                Button {
                    store.remove(source.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("删除该源")
            } else {
                Text("内置")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 添加源

    private var addSourceSheet: some View {
        AddSourceForm { title, urlString in
            store.addCustom(title: title, urlString: urlString)
        }
    }
}
