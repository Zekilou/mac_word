import SwiftUI

/// 词块显示状态（初始化 / RSS / 生成文章 / 词表 / 卡片浏览 / 词典共用）。
/// **概率主口径**：有 BKT 后验概率时按概率档位判定；没有概率才回退到用户显式标记。
/// @ai: `.learning` 携带的是**概率（0~1）**，不再是旧的 mastery（1~2）。
enum WordMarkState: Equatable {
    /// 已会（概率 ≥ knownThreshold，绿）。
    case known
    /// 不会（概率 ≤ unknownThreshold，红）。
    case unknown
    /// 学习中（携带概率 0~1，琥珀单色）。
    case learning(Double)
    /// 出现过未确认（蓝）——被动看到且模型还没有概率。
    case seen
    /// 无记录未见过（灰，待标记）。
    case pending

    /// 概率档位阈值（全应用唯一定义处，禁止各页散落魔法数字）。
    static let knownThreshold = 0.85
    static let unknownThreshold = 0.20

    /// 概率主口径判定：有后验概率 → 概率档位；无概率 → 回退显式标记。
    static func from(belief: Double?, mastery: Double?, seenCount: Int) -> WordMarkState {
        guard let belief else {
            return from(mastery: mastery, seenCount: seenCount)
        }
        if belief >= knownThreshold { return .known }
        if belief <= unknownThreshold { return .unknown }
        return .learning(belief)
    }

    /// 旧口径兜底：用户显式标记（mastery 0/1/2）。仅在模型还没有概率时使用。
    static func from(mastery: Double?, seenCount: Int) -> WordMarkState {
        guard let m = mastery, m > 0 else {
            return seenCount > 0 ? .seen : .pending
        }
        if m >= 1.999 { return .known }
        if m <= 1.001 { return .unknown }
        return .learning(m - 1.0)
    }

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

    /// 中文标签（图例 / 列表 / 计数用）。
    var label: String {
        switch self {
        case .known: return "已会"
        case .unknown: return "不会"
        case .learning(let belief): return "学习中 \(MasteryPresentation.percentText(belief))"
        case .seen: return "出现过"
        case .pending: return "无记录"
        }
    }
}
