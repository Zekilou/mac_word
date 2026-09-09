import SwiftUI

/// 词块图例：统一从 `WordMarkState.legendItems` 取色，禁止各页手写。
struct WordMarkLegendView: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(WordMarkState.legendItems) { item in
                HStack(spacing: 3) {
                    Circle().fill(item.color.opacity(0.85)).frame(width: 7, height: 7)
                    Text(item.label).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}
