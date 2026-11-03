import SwiftUI
import AppKit

// ============================================================================
// FlipLab —— 翻卡透视调参台（独立小程序，不属于 WordRecitingApp）
//
// 编译（约 2 秒，无需全量 build）：
//     tools/flip-lab/build.sh
// 运行：
//     tools/flip-lab/build.sh --run
//
// 为什么要有这个：
//   主 App 每次改一个动画常数都要重新编译整个 AppKit/SwiftUI 包（10+ 秒），
//   调手感时轮次太慢。这里把「透视 / 翻转角度 / 卡片尺寸」抽成滑杆，
//   拖一下就能看到效果，定值后抄回 `CardFlipMotion.swift` 即可。
//
// @ai: 本文件的 `LabFlip` / `LabMotion` **必须与主包的两个文件逐行对应**：
//        Sources/WordRecitingApp/UI/Study/Card3DFlip.swift     （CATransform3D 变换）
//        Sources/WordRecitingApp/UI/Study/CardFlipMotion.swift （显隐/明暗/缩放）
//      改了一边记得同步另一边，否则调参台和真页面手感会对不上。
// ============================================================================

/// 与 Card3DFlip / CardFlipMotion 同源的翻卡参数（本文件内联一份，避免依赖主包）。
enum LabMotion {
    static let fullTurn: Double = 180

    static func normalize(_ degrees: Double) -> Double {
        let cycle = fullTurn * 2
        var d = degrees.truncatingRemainder(dividingBy: cycle)
        if d < 0 { d += cycle }
        if d > fullTurn { d = cycle - d }
        return d
    }

    /// 正面不透明度（80°–100° 交叉淡出）。
    static func frontVisible(_ degrees: Double) -> Double {
        let d = normalize(degrees)
        if d <= 80 { return 1 }
        if d >= 100 { return 0 }
        return (100 - d) / 20
    }

    static func backVisible(_ degrees: Double) -> Double { 1 - frontVisible(degrees) }

    static func shading(_ degrees: Double) -> Double {
        1 - 0.18 * (1 - abs(cos(normalize(degrees) / fullTurn * .pi)))
    }

    static func scale(_ degrees: Double) -> CGFloat {
        let lift = abs(sin(normalize(degrees) / fullTurn * .pi))
        return 1 - 0.045 * lift
    }

    static func liftOffset(_ degrees: Double) -> CGFloat {
        let lift = abs(sin(normalize(degrees) / fullTurn * .pi))
        return -6 * lift
    }
}

/// 与主 App `Card3DFlip` **逐行对应**的实现：单个 CATransform3D 完成
/// 「平移到中心 → 旋转 → 平移回去」，透视强度 m34 = -1/(strength × max(w,h))。
struct LabFlip: GeometryEffect {
    var angle: Double
    var strength: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let a = CGFloat(angle * .pi / 180)
        var t = CATransform3DIdentity
        t.m34 = -1 / (max(strength, 0.01) * max(size.width, size.height))
        // 左乘语义：从内向外写 T(+c) · P · R · T(-c)，旋转轴才落在卡片中心。
        let cx = size.width / 2
        let cy = size.height / 2
        t = CATransform3DTranslate(t, cx, cy, 0)
        t = CATransform3DRotate(t, a, 0, 1, 0)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return ProjectionTransform(t)
    }
}

// MARK: - 可调参数面板

struct FlipLabView: View {
    @State private var strength: Double = 4.0
    @State private var degrees: Double = 0
    @State private var cardWidth: Double = 520
    @State private var cardHeight: Double = 340
    @State private var cornerRadius: Double = 20
    @State private var showTilt = true
    @State private var showScale = true
    @State private var slowMotion = false
    @State private var animate = false

    private var effectiveDegrees: Double { animate ? 180 : degrees }

    /// 转身 90° 时近端边缘的放大率（仅作参考显示；渲染本身由 CATransform3D 决定）。
    private var magnification: Double {
        let d = strength * max(cardWidth, cardHeight)
        let half = cardWidth / 2
        return d / max(d - half, 1)
    }

    var body: some View {
        HSplitView {
            stage
            controls
        }
        .frame(minWidth: 980, minHeight: 620)
    }

    // MARK: 舞台

    private var stage: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 22) {
                card
                    .frame(width: cardWidth, height: cardHeight)
                Text(String(format: "角度 %.0f°   透视强度 %.2f",
                            LabMotion.normalize(effectiveDegrees), strength))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 560)
    }

    private var card: some View {
        let d = effectiveDegrees
        return ZStack {
            face(back: false, text: "abandon\n/\u{0259}\u{02C8}b\u{00E6}nd\u{0259}n/")
                .opacity(LabMotion.frontVisible(d))
            face(back: true, text: "\u{653E}\u{5F03} \u{00B7} \u{629B}\u{5F03}\nShe abandoned the plan.")
                .opacity(LabMotion.backVisible(d))
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(width: cardWidth, height: cardHeight)
        .modifier(LabFlip(angle: LabMotion.normalize(d), strength: CGFloat(strength)))
        .scaleEffect(showScale ? LabMotion.scale(d) : 1)
        .offset(y: showScale ? LabMotion.liftOffset(d) : 0)
        .brightness(-0.06 * (1 - LabMotion.shading(d)))
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
                .shadow(color: .black.opacity(0.16 * LabMotion.shading(d)),
                        radius: 18 * LabMotion.shading(d) + 4,
                        y: 8 * LabMotion.shading(d) + 2)
        )
        .animation(slowMotion
                   ? .spring(response: 1.6, dampingFraction: 0.82)
                   : .spring(response: 0.46, dampingFraction: 0.82),
                   value: d)
    }

    private func face(back: Bool, text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(back
                      ? AnyShapeStyle(Color(nsColor: .textBackgroundColor))
                      : AnyShapeStyle(LinearGradient(
                            colors: [Color(nsColor: .controlBackgroundColor),
                                     Color(nsColor: .textBackgroundColor)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(back ? 0.10 : 0.14), lineWidth: 1)
            Text(text)
                .font(.system(size: back ? 20 : 40, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(28)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: 控制面板

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("翻卡透视调参").font(.headline)

                group("透视强度（无量纲）") {
                    Text("相机距离 = 强度 × 卡片长边。1 = 贴近卡片（夸张），4 = 自然，≥8 = 近乎平面。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $strength, in: 1...20)
                        Text(String(format: "%.2f", strength))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        ForEach([1.5, 2.0, 3.0, 4.0, 6.0, 10.0, 20.0], id: \.self) { v in
                            Button(String(format: "%.1f", v)) { strength = v }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                    Text("当前：转向 90° 时近端放大 \(String(format: "%.2f", magnification))×")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                group("翻转角度") {
                    HStack {
                        Slider(value: $degrees, in: 0...180)
                        Text(String(format: "%.0f°", degrees))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Button("正面 0°") { animate = false; degrees = 0 }
                        Button("侧棱 90°") { animate = false; degrees = 90 }
                        Button("背面 180°") { animate = false; degrees = 180 }
                        Button(animate ? "停止动画" : "播放翻转") {
                            animate.toggle()
                            degrees = animate ? 180 : 0
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .font(.caption)
                }

                group("卡片尺寸") {
                    HStack {
                        Text("宽").font(.caption).frame(width: 20, alignment: .leading)
                        Slider(value: $cardWidth, in: 300...700)
                        Text("\(Int(cardWidth))").font(.system(size: 12, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("高").font(.caption).frame(width: 20, alignment: .leading)
                        Slider(value: $cardHeight, in: 200...500)
                        Text("\(Int(cardHeight))").font(.system(size: 12, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("圆角").font(.caption).frame(width: 32, alignment: .leading)
                        Slider(value: $cornerRadius, in: 0...40)
                        Text("\(Int(cornerRadius))").font(.system(size: 12, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                group("动画细节") {
                    Toggle("X 轴倾斜（卡片被掀起一角）", isOn: $showTilt)
                    Toggle("缩放 + 抬升", isOn: $showScale)
                    Toggle("慢放（2 秒）", isOn: $slowMotion)
                }

                Divider()
                Text("定稿参数抄回 CardFlipMotion.swift。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .frame(width: 340)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 入口

@main
struct FlipLabApp: App {
    var body: some Scene {
        WindowGroup("FlipLab — 翻卡透视调参") {
            FlipLabView()
        }
        .windowResizability(.contentMinSize)
    }
}
