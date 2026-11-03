import SwiftUI
import WordRecitingCore

/// 词块图例：统一从 `WordMarkState.legendItems` 取色，禁止各页手写。
struct WordMarkLegendView: View {
    var body: some View {
        HStack(spacing: Space.m) {
            ForEach(WordMarkState.legendItems) { item in
                HStack(spacing: Space.xxs) {
                    Circle().fill(item.color.opacity(0.85)).frame(width: Size.dotSmall, height: Size.dotSmall)
                    Text(item.label).foregroundStyle(Ink.secondary)
                }
            }
        }
        .font(Type.caption)
    }
}
