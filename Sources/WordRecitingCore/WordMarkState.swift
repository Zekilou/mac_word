import Foundation

/// 词块显示状态（初始化 / RSS / 生成文章 / 词表 / 卡片浏览 / 词典共用）。
/// **概率主口径**：有 BKT 后验概率时按概率档位判定；没有概率才回退到用户显式标记。
///
/// @ai: 这个枚举是**领域概念**，不是 UI 概念——`WordCore.markState` 也依赖它，
///      所以它住在 Core 层。**颜色**是 UI 关注点，放在 WordRecitingUI 的同名扩展里
///      （`WordMarkState+Color.swift`）。两者分属不同模块，判定逻辑与配色各自独立演进。
public enum WordMarkState: Equatable, Sendable {
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
    public static let knownThreshold = 0.85
    public static let unknownThreshold = 0.20

    /// 概率主口径判定：有后验概率 → 概率档位；无概率 → 回退显式标记。
    public static func from(belief: Double?, mastery: Double?, seenCount: Int) -> WordMarkState {
        guard let belief else {
            return from(mastery: mastery, seenCount: seenCount)
        }
        if belief >= knownThreshold { return .known }
        if belief <= unknownThreshold { return .unknown }
        return .learning(belief)
    }

    /// 旧口径兜底：用户显式标记（mastery 0/1/2）。仅在模型还没有概率时使用。
    public static func from(mastery: Double?, seenCount: Int) -> WordMarkState {
        guard let m = mastery, m > 0 else {
            return seenCount > 0 ? .seen : .pending
        }
        if m >= 1.999 { return .known }
        if m <= 1.001 { return .unknown }
        return .learning(m - 1.0)
    }

    /// 中文标签（图例 / 列表 / 计数用）。
    public var label: String {
        switch self {
        case .known: return "已会"
        case .unknown: return "不会"
        case .learning(let belief): return "学习中 \(MasteryPresentation.percentText(belief))"
        case .seen: return "出现过"
        case .pending: return "无记录"
        }
    }
}
