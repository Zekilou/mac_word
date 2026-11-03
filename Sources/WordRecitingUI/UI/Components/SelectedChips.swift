import SwiftUI
import WordRecitingCore

/// 已选目标词概览（L2 复合组件）：计数 + 折叠式词标签墙（复用 ChipWall，词多不撑爆布局）。
struct SelectedChips: View {
    let words: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("已选 \(words.count) 个目标词")
                .font(Type.caption)
                .foregroundStyle(Ink.secondary)
            if !words.isEmpty {
                ChipWall(words: words) { w in
                    PlainChip(word: w)
                }
            }
        }
    }
}
