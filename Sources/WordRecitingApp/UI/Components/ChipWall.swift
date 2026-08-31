import SwiftUI

/// 内嵌列表式词标签墙（L2 复合组件）：
/// 词多时默认只显示前 maxVisible 个，底部「更多 N 个…」按钮展开/收起；
/// 标签区为**限高内嵌列表**（.frame(maxHeight: wallHeight) + 内部滚动）——
/// 词再多高度也被卡在上限内内部滚动，不参与/不挤动外部布局。
/// @ai: FlowChips 的通用替代（FlowChips 无折叠无限高，词上百时全铺塞不下/撑爆布局）；
///      纯布局组件，不写 SQL；@State expanded 仅视图内状态，不影响外部数据。
struct ChipWall<Chip: View>: View {
    let words: [String]
    var maxVisible: Int
    var spacing: CGFloat
    var minWidth: CGFloat
    /// 标签区内嵌列表高度上限（超限内部滚动）。
    var wallHeight: CGFloat
    let chip: (String) -> Chip

    @State private var expanded = false

    init(words: [String], maxVisible: Int = 40, spacing: CGFloat = 6,
         minWidth: CGFloat = 80, wallHeight: CGFloat = 96,
         @ViewBuilder chip: @escaping (String) -> Chip) {
        self.words = words
        self.maxVisible = maxVisible
        self.spacing = spacing
        self.minWidth = minWidth
        self.wallHeight = wallHeight
        self.chip = chip
    }

    var body: some View {
        let shown = expanded ? words : Array(words.prefix(maxVisible))
        VStack(alignment: .leading, spacing: 4) {
            // 内嵌列表：限高 + 内部滚动，高度稳定不随词数撑爆外部布局
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: spacing)],
                          alignment: .leading, spacing: spacing) {
                    ForEach(shown, id: \.self) { w in
                        chip(w)
                    }
                }
            }
            .frame(maxHeight: wallHeight)
            if words.count > maxVisible {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "收起" : "更多 \(words.count - maxVisible) 个…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(expanded ? "折叠标签墙" : "展开全部标签")
            }
        }
    }
}

/// 默认样式的纯词标签（ChipWall 的便捷 chip）。
struct PlainChip: View {
    let word: String
    var body: some View {
        Text(word)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
    }
}
