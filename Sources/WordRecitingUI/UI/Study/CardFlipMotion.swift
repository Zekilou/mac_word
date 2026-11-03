import SwiftUI
import WordRecitingCore

/// 翻卡动画的「实体感」参数：把「翻转角度」映射成透视、明暗、缩放、正反面可见性。
///
/// @ai: 为什么单独立成纯函数而不是散在 View 里——
///      - 翻转是**一次**角度动画（0° → 180°），正反面可见性必须由角度**推导**，
///        不能用两个独立的布尔动画（那样两面会在中途同时出现/同时消失，实体感立刻崩）；
///      - 角度区间/阈值/系数是手感参数，需要可单测（`CardFlipMotionTests`）、需要集中调；
///      - View 只负责画，判定逻辑不许在 `body` 里写魔法数字（历史 bug 都是这么来的）。
enum CardFlipMotion {

    /// 一次完整翻转的角度（度）。
    static let fullTurn: Double = 180

    /// 半程判定阈值（度）。越过它才算「翻过去了」——用于点击/评分时判断当前朝向。
    /// @ai: 用 90 而非「角度 ↔ 180 的一半」这种隐式写法，避免将来改成非 180° 翻页时判定错位。
    static let halfTurn: Double = 90

    /// 透视强度（**无量纲**）：相机距离 = `strength × max(卡片宽, 高)`。
    /// - 1   → 相机贴边，90° 时近端趋于无限高（夸张、会撕裂）
    /// - 2   → 近端约 1.5×，立体感明显
    /// - 4   → 近端约 1.14×，克制自然（默认）
    /// - ≥8  → 肉眼近乎平行投影
    /// @ai: 无量纲是刻意的——绝对点数（旧代码的 420/2000/10000）换个卡片尺寸就全乱，
    ///      而且无法判断「这个值算大还是算小」。这里数值直接决定可感知的立体度。
    ///      调参用 `tools/flip-lab`（2 秒编译，滑杆实时改，不必全量 build）。
    static let defaultPerspectiveStrength: CGFloat = 4.0

    /// 是否处于正面（角度 < 90° 为正面）。
    /// 仅用于**意图**判定；渲染时的显隐统一走 `frontVisible` / `backVisible`（含淡入淡出窗口）。
    static func isFront(_ degrees: Double) -> Bool {
        normalize(degrees) < halfTurn
    }

    /// 把任意角度归一化到 [0, 180)：超过 180 视为又翻回正面一侧。
    static func normalize(_ degrees: Double) -> Double {
        let cycle = fullTurn * 2
        var d = degrees.truncatingRemainder(dividingBy: cycle)
        if d < 0 { d += cycle }
        if d > fullTurn { d = cycle - d }
        return d
    }

    /// 正面不透明度。
    /// @ai: 显隐用**带窗口的阶跃**而不是 `angle < 90 ? 1 : 0`：
    ///      阶跃在 90° 瞬间切换会闪一下；这里让两面在 80°–100° 之间交叉淡出，
    ///      恰好是卡片呈侧棱、最看不清的时刻，于是切换「看不见」。
    static func frontVisible(_ degrees: Double) -> Double {
        let d = normalize(degrees)
        if d <= halfTurn - 10 { return 1 }
        if d >= halfTurn + 10 { return 0 }
        return (halfTurn + 10 - d) / 20
    }

    /// 背面不透明度（与正面互补）。
    static func backVisible(_ degrees: Double) -> Double {
        1 - frontVisible(degrees)
    }

    /// 明暗系数（0.82～1）：翻到侧棱时略暗，模拟受光面转向。
    /// @ai: `|cos|` 在 0°/180° 为 1、90° 为 0——所以平放时最亮、侧棱时最暗。
    ///      写成 `1 - 0.18 * |cos|` 会把明暗**反过来**（平放变暗、侧棱变亮），
    ///      视觉上像卡片自发光，`CardFlipMotionTests` 钉住了这个方向。
    static func shading(_ degrees: Double) -> Double {
        1 - 0.18 * (1 - abs(cos(normalize(degrees) / fullTurn * .pi)))
    }

    /// 近大远小系数：卡片立起来的一瞬间略微缩小，落回去再放大。
    static func scale(_ degrees: Double) -> CGFloat {
        let lift = abs(sin(normalize(degrees) / fullTurn * .pi))   // 0→1→0
        return 1 - 0.045 * lift
    }

    /// 翻到侧棱时的抬升偏移（点，负值向上）：卡片「离开桌面」一点点。
    static func liftOffset(_ degrees: Double) -> CGFloat {
        let lift = abs(sin(normalize(degrees) / fullTurn * .pi))
        return -6 * lift
    }

    /// 是否已经落在某一面（0° 或 180°）。用于「翻的过程中不响应点击」。
    static func isSettled(_ degrees: Double) -> Bool {
        let d = normalize(degrees)
        return d < 1 || d > fullTurn - 1
    }
}
