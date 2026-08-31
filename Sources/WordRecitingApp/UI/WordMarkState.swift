import SwiftUI

/// 词块显示状态（初始化 / RSS 阅读 / 词表等词块 UI 共用）。
/// 优先级：会话覆盖 > 全局掌握度（会/不会/学习中）> 出现过（seen）> 未标记。
/// @ai: 掌握度值域 1(完全不会)~2(完全会)；只有两端极值是"会/不会"，中间值一律"学习中"（显示渐变颜色）。
enum WordMarkState: Equatable {
    /// 已会（极端：mastery ≥ 2，绿）。
    case known
    /// 不会（极端：mastery ≤ 1，红）。
    case unknown
    /// 学习中（掌握度在 1~2 之间，显示掌握度对应的渐变颜色）。
    case learning(Double)
    /// 出现过未确认（蓝）——RSS 等文章自动记录，未判定会/不会。
    case seen
    /// 无记录未见过（灰，待标记）。
    case pending

    /// 统一状态判定：掌握度（会/不会/学习中）> 出现过（seen）> 无记录。
    /// 掌握度值域：0/无 = 无记录；1 = 不会；2 = 会；1< m <2 = 学习中。
    /// 两端极值用容差 0.001 判定（浮点存储偏差）。
    /// @ai: 各模块（初始化/RSS/词表/分析）必须用此函数判定，保证能力数据口径一致。
    static func from(mastery: Double?, seenCount: Int) -> WordMarkState {
        guard let m = mastery, m > 0 else {
            return seenCount > 0 ? .seen : .pending
        }
        if m >= 1.999 { return .known }
        if m <= 1.001 { return .unknown }
        return .learning(m)
    }

    /// 词块底色：会→绿 / 不会→红 / 学习中→按掌握度渐变（1 红 → 1.5 黄 → 2 绿）/ 出现过→蓝 / 无记录→灰。
    var color: Color {
        switch self {
        case .known: return .green
        case .unknown: return .red
        case .learning(let m):
            // hue 0(红) → 0.166(黄) → 0.333(绿)，按掌握度线性插值
            let t = min(1, max(0, (m - 1.0)))
            let hue = t * 120 / 360
            return Color(hue: hue, saturation: 0.8, brightness: 0.8)
        case .seen: return .blue
        case .pending: return .gray
        }
    }

    /// 中文标签（图例 / 列表 / 计数用）。
    var label: String {
        switch self {
        case .known: return "已会"
        case .unknown: return "不会"
        case .learning(let m): return String(format: "学习中 %.1f", m)
        case .seen: return "出现过"
        case .pending: return "无记录"
        }
    }
}
