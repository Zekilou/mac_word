import SwiftUI
import WordRecitingCore

/// 背诵闪卡：一张**有实体感**的双面卡片，翻面是一次真实的 3D 翻转。
///
/// @ai: 实现要点（改前必读）：
///      1. **只做一次 3D 变换**：整张卡走 `Card3DFlip`（单个 `CATransform3D`）。
///         禁止再叠 `.rotation3DEffect` —— 两个透视投影相乘会把近裁面压到卡片上，
///         90° 时近侧被放大到「无限高」。详见 `Card3DFlip` 的类型注释。
///      2. **两面都在同一个变换里**：背面预先 `rotation3DEffect(180)` 抵消镜像，
///         显隐由角度推导（`CardFlipMotion.frontVisible/backVisible`）。
///      3. **尺寸固定**：两面同框，翻面不跳（旧实现两面各自撑高，命中区会漂）。
///      4. **不要 `.textSelection(.enabled)`**：macOS 上会吞掉点击手势
///         （备忘录 2026-08-12 记录过的翻转失效根因）。
struct FlashCard<Front: View, Back: View>: View {
    /// 朝向：true = 显示正面（词面）。
    let isFront: Bool
    /// 透视强度（见 `Card3DFlip.perspectiveStrength`）。
    var perspectiveStrength: CGFloat = CardFlipMotion.defaultPerspectiveStrength
    /// 点击整张卡。
    let onFlip: () -> Void
    @ViewBuilder let front: () -> Front
    @ViewBuilder let back: () -> Back

    /// 当前角度：0 = 正面，180 = 背面。
    /// @ai: 整个翻转动画只补间这一个数值（`animatableData`），
    ///      不要再引入任何「第二段动画」。
    @State private var angle: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 翻面动画：阻尼回弹，模拟卡片被放开后「啪」地落平。
    private let flipAnimation = Animation.spring(response: 0.46, dampingFraction: 0.82)

    var body: some View {
        ZStack {
            frontSide
                .opacity(CardFlipMotion.frontVisible(angle))
                .allowsHitTesting(isFront)
            backSide
                .opacity(CardFlipMotion.backVisible(angle))
                .allowsHitTesting(!isFront)
        }
        .frame(width: StudyCardStyle.width, height: StudyCardStyle.height)
        // 唯一的 3D 变换：旋转 + 透视 + 居中锚点，一次投影。
        .modifier(Card3DFlip(
            angle: CardFlipMotion.normalize(angle),
            perspectiveStrength: perspectiveStrength))
        // 侧棱处略微缩小 / 抬升：让卡片像被手指掀起，而不是原地绕轴。
        .scaleEffect(CardFlipMotion.scale(angle))
        .offset(y: CardFlipMotion.liftOffset(angle))
        // 明暗：翻到侧棱时略暗（受光面转开）。
        .brightness(-0.06 * (1 - CardFlipMotion.shading(angle)))
        .background(
            RoundedRectangle(cornerRadius: StudyCardStyle.cornerRadius, style: .continuous)
                .fill(Color.clear)
                .shadow(
                    color: .black.opacity(0.16 * CardFlipMotion.shading(angle)),
                    radius: 18 * CardFlipMotion.shading(angle) + 4,
                    y: 8 * CardFlipMotion.shading(angle) + 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: StudyCardStyle.cornerRadius))
        .onTapGesture { onFlip() }
        .animation(reduceMotion ? nil : flipAnimation, value: angle)
        .onChange(of: isFront) { _, newValue in
            angle = newValue ? 0 : CardFlipMotion.fullTurn
        }
        .onAppear {
            angle = isFront ? 0 : CardFlipMotion.fullTurn
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isFront ? "卡片正面，点按查看释义" : "卡片背面，点按回到正面")
    }

    private var frontSide: some View {
        StudyCardSurface(back: false) { front() }
    }

    private var backSide: some View {
        StudyCardSurface(back: true) { back() }
            // @ai: 背面内容先自转 180°，抵消「转到 180° 时内容正面朝里」的镜像。
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
    }
}

// MARK: - 卡面底板

/// 卡片底板：正面（浅色、词重）与背面（略暖、释义）两种材质 + 圆角 + 描边。
/// @ai: 底板与内容分离，保证两面圆角/边框完全一致——否则翻转时会看见「两层的边」错位。
struct StudyCardSurface<Content: View>: View {
    let back: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: StudyCardStyle.cornerRadius, style: .continuous)
                .fill(background)
            RoundedRectangle(cornerRadius: StudyCardStyle.cornerRadius, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: StudyCardStyle.cornerRadius, style: .continuous))
    }

    private var background: LinearGradient {
        if back {
            return LinearGradient(
                colors: [Color(nsColor: .textBackgroundColor),
                         Color(nsColor: .textBackgroundColor).opacity(0.82)],
                startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(
            colors: [Color(nsColor: .controlBackgroundColor),
                     Color(nsColor: .textBackgroundColor)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var border: Color {
        back ? Color.primary.opacity(0.10) : Color.primary.opacity(0.14)
    }
}

/// 闪卡视觉常量（两面共用，禁止各写一份）。
enum StudyCardStyle {
    static let cornerRadius: CGFloat = 20
    static let width: CGFloat = 520
    static let height: CGFloat = 340
    static var size: CGSize { CGSize(width: width, height: height) }
}
