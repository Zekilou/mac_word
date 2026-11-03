import SwiftUI
import WordRecitingCore

/// 翻卡的 3D 变换：**单个 CATransform3D** 完成旋转 + 透视 + 锚点居中。
///
/// @ai: 这是本轮重写的核心，改前必须读完。旧实现（两个叠加的 `rotation3DEffect`）错在：
///
///   1. **两个透视投影相乘 ≠ 3D 空间里的复合旋转。**
///      叠加 `.rotation3DEffect(axis: y)` 与 `.rotation3DEffect(axis: x)` 时，
///      每个 modifier 各自生成一套投影矩阵，两次投影复合会把近裁面压到卡片身上，
///      90° 时近侧边被推到相机平面附近 →「近侧无限高」。正确做法是用
///      一个 `CATransform3D` 先 `CATransform3DRotate` 再 `ProjectionTransform`，
///      只做**一次**投影（SwiftUI Lab 的 FlipEffect 即此结构）。
///
///   2. **透视强度必须相对卡片尺寸。** `m34 = -1/d`，其中 d 是相机距离；
///      卡片半宽 w/2 转到 90° 时 z 位移 ≈ w/2，放大率 = 1/(1 - (w/2)/d)。
///      旧代码取 d=420 而卡片宽 520 → 放大率 2.6×（撕裂）。取 d 与尺寸挂钩
///      （`card width * strength`）时，放大率只由 strength 决定，与卡片大小无关，
///      这才可预测、可调。
///
///   3. **锚点**：SwiftUI 的 `ProjectionTransform` 以左上角为原点，
///      所以必须 translate(-w/2,-h/2) → rotate → translate(w/2,h/2)，
///      否则卡片会绕左上角甩出去。这里在 effectValue 里显式处理。
struct Card3DFlip: GeometryEffect {

    /// 翻转角度（度）。0 = 正面，180 = 背面。整个动画只补间这一个值。
    var angle: Double

    /// 绕哪个轴翻（单位向量）。默认 Y 轴（左右翻）。
    var axis: (x: CGFloat, y: CGFloat, z: CGFloat) = (0, 1, 0)

    /// 透视强度：相机距离 = `strength × max(宽,高)`。
    /// - 1.0 → 相机贴到卡片边缘，放大率趋于 ∞（夸张，会撕裂）
    /// - 2.0 → 转向 90° 时近端约 1.5×（明显的立体感，仍可控）
    /// - 4.0 → 约 1.14×（很克制，接近平行投影）
    /// - ≥8  → 肉眼几乎无透视（纯平面翻转）
    /// @ai: 这是**唯一**的透视旋钮。它无量纲，所以换卡片尺寸手感不变——
    ///      旧代码用绝对点数（420/2000/10000），换个尺寸就全乱。
    var perspectiveStrength: CGFloat = 4.0

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let a = CGFloat(angle * .pi / 180)
        let axisLength = sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
        guard axisLength > 0 else { return ProjectionTransform(.identity) }

        var t = CATransform3DIdentity
        // 透视：m34 = -1/d，d 与卡片尺寸挂钩（见类型注释第 2 点）。
        let cameraDistance = max(perspectiveStrength, 0.01) * max(size.width, size.height)
        t.m34 = -1 / cameraDistance

        // 把旋转轴搬到卡片正中心。
        // @ai: CATransform3DTranslate 是**左乘**（`t' = T · t`），所以调用顺序要从内向外写：
        //        T(+c) · P · R · T(-c)
        //      写成先 T(-c) 再 R 再 T(+c)，实际矩阵是 T(-c)·R·T(+c)·P，
        //      不动点落在 -c（左上角外侧），表现就是「卡片绕着卡片外面的一个点甩」。
        //      这是本轮修掉的居中问题。
        let cx = size.width / 2
        let cy = size.height / 2
        t = CATransform3DTranslate(t, cx, cy, 0)              // 1) 最后把中心移回原位
        t = CATransform3DRotate(                              // 2) 绕中心旋转
            t, a, axis.x / axisLength, axis.y / axisLength, axis.z / axisLength)
        t = CATransform3DTranslate(t, -cx, -cy, 0)            // 3) 先把原点挪到中心
        return ProjectionTransform(t)
    }
}

extension Card3DFlip {
    /// 翻过 90° 后背面才朝前（用于判断该显示哪一面）。
    var showsBack: Bool { CardFlipMotion.normalize(angle) >= CardFlipMotion.halfTurn }
}
