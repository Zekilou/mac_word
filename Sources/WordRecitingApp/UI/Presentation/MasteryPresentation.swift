import Foundation

/// 掌握度概率的展示格式化（纯函数，可单测；不放 SwiftUI 依赖）。
enum MasteryPresentation {

    /// 百分比文案，如 "85%"。输入钳制到 [0,1]。
    static func percentText(_ belief: Double) -> String {
        let clamped = min(max(belief, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// 档位序号 0..3（视图据此选颜色）。
    static func levelIndex(_ belief: Double) -> Int {
        switch belief {
        case ..<0.35: return 0
        case ..<0.70: return 1
        case ..<0.90: return 2
        default: return 3
        }
    }

    /// 档位中文标签。
    static func levelLabel(_ belief: Double) -> String {
        switch levelIndex(belief) {
        case 0: return "低"
        case 1: return "中"
        case 2: return "较高"
        default: return "高"
        }
    }

    /// tooltip（必须说明不确定性）。
    static func helpText(_ belief: Double) -> String {
        "模型估计掌握度 \(percentText(belief))（BKT 后验概率，随每次事件更新，不是精确测量）"
    }

    /// 无模型数据占位。
    static let noDataText = "—"

    /// 证据来源图标（SF Symbol）：显式标记 > 模型推断 > 被动 seen。
    /// @ai: 来源用图标区分，不占颜色通道（颜色只表档位）。
    static func sourceIcon(explicit: Bool, hasBelief: Bool) -> String {
        if explicit { return "hand.tap" }
        if hasBelief { return "waveform.path.ecg" }
        return "eye"
    }
}
