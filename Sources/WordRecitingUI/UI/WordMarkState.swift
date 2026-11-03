import SwiftUI
import WordRecitingCore

/// `WordMarkState` 的**配色**（UI 关注点）。
///
/// @ai: 判定逻辑（档位阈值、from(belief:mastery:)）在 Core 层的 `WordMarkState` 里，
///      因为 `WordCore.markState` 也依赖它。这里只放颜色与图例——
///      颜色是渲染决策，不该把 SwiftUI 拖进数据层。
extension WordMarkState {

    /// 词块底色：只表 3 档（会→绿 / 学习中→琥珀 / 不会→红）+ 出现过→蓝 / 无记录→灰。
    /// @ai: 颜色只表档位，连续概率用数字（`MasteryPresentation.percentText`）表达。
    var color: Color {
        switch self {
        case .known: return .green
        case .unknown: return .red
        case .learning: return .orange
        case .seen: return .blue
        case .pending: return .gray
        }
    }

    /// 图例项（全应用图例统一从这里取，禁止各页手写颜色）。
    struct LegendItem: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let color: Color
    }

    static var legendItems: [LegendItem] {
        [
            LegendItem(label: "会", color: WordMarkState.known.color),
            LegendItem(label: "学习中", color: WordMarkState.learning(0.5).color),
            LegendItem(label: "不会", color: WordMarkState.unknown.color),
            LegendItem(label: "出现过", color: WordMarkState.seen.color),
            LegendItem(label: "未见", color: WordMarkState.pending.color)
        ]
    }
}
