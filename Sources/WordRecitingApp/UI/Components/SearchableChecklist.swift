import SwiftUI

/// 可搜索勾选列表（L2 复合组件，spec §5.3 可搜索列表三件套之一）：
/// 搜索框（本地过滤，词形/释义）+ 懒加载勾选列表（点击整行切换）+ 空态。
/// 大词库安全：LazyVStack 只渲染可见行；filtered 空关键字返回全量。
struct SearchableChecklist<Item: Identifiable>: View {
    let items: [Item]
    let placeholder: String
    let searchKey: (Item) -> String
    let title: (Item) -> String
    let subtitle: (Item) -> String?
    let isSelected: (Item) -> Bool
    let toggle: (Item) -> Void
    /// 行尾徽章（可选）：返回 (文案, 颜色)；nil = 不显示。
    /// @ai: `var` 才能进 memberwise init 的默认参数（`let` 带初值会被省略）。
    var badge: ((Item) -> (text: String, color: Color)?)? = nil

    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { item in
                        row(item)
                    }
                }
            }
            .frame(maxHeight: .infinity)   // 弹性撑满剩余高度，随窗口伸缩
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if filtered.isEmpty {
                    Text("无匹配结果")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 本地过滤：词形 + 释义子串（大小写不敏感）。
    private var filtered: [Item] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { searchKey($0).lowercased().contains(q) }
    }

    private func row(_ item: Item) -> some View {
        Button {
            toggle(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected(item) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected(item) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(item)).font(.body)
                    if let s = subtitle(item), !s.isEmpty {
                        Text(s)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let badge = badge?(item) {
                    Text(badge.text)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badge.color.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
