import SwiftUI

/// 文本溢出时水平滚动（marquee），不溢出时静态显示。
/// @ai: 通用组件，左下角全局进度胶囊/工具栏长文本均可复用。
///      检测机制：用 GeometryReader 测容器宽，Text(.layout) 测真实宽，差值 > 0 启动动画。
///      动画：从右对齐（看到开头）→ 停 0.7s → 滚到左对齐（看到末尾）→ 停 1.5s → 复位 → 循环。
///      鼠标 hover 时加速循环（即使没溢出也可触发完整查看）；ReducedMotion 时禁用动画直接静态。
struct MarqueeText: View {
    let text: String
    var font: Font = .caption
    var color: Color = .primary
    /// 永远滚动（即使不溢出）；默认 false 仅溢出时滚动。
    var alwaysScroll: Bool = false

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isHovering = false
    @State private var phase: Phase = .idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 动画阶段机：idle（停在开头）→ pause → scrolling（滚到末尾）→ pauseEnd → reset。
    private enum Phase: Equatable {
        case idle, pauseBeforeScroll, scrolling, pauseAtEnd, resetting
    }

    private var isOverflow: Bool {
        guard containerWidth > 0 else { return false }
        return textWidth > containerWidth + 1   // 1pt 容差
    }

    private var shouldScroll: Bool {
        (isOverflow || alwaysScroll) && !reduceMotion && !text.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            textLayer
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, new in containerWidth = new }
                .background(
                    // 隐藏测量层：用 Text 的 layout 维度测真实宽（不受容器约束）
                    Text(text)
                        .font(font)
                        .background(GeometryReader { p in
                            Color.clear.onAppear { textWidth = p.size.width }
                                .onChange(of: p.size.width) { _, new in textWidth = new }
                        })
                        .fixedSize()
                        .hidden()
                )
        }
        .frame(height: textHeight)
        .onHover { isHovering = $0 }
        .clipped()
        .onAppear { startAnimationIfNeeded() }
        .onChange(of: shouldScroll) { _, _ in startAnimationIfNeeded() }
        .onChange(of: text) { _, _ in
            // 文本变化时复位
            offset = 0
            phase = .idle
            startAnimationIfNeeded()
        }
    }

    /// 估算文本高度（font 一致即可，与 Text 自然高度对齐）。
    private var textHeight: CGFloat {
        font == .caption ? 14 : (font == .caption2 ? 12 : 16)
    }

    private var textLayer: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)   // 不被容器压扁
            .frame(width: max(textWidth, containerWidth), alignment: .leading)
            .offset(x: offset)
            .frame(width: containerWidth, alignment: .leading)   // 容器对齐
    }

    // MARK: - 动画循环

    private func startAnimationIfNeeded() {
        guard shouldScroll else {
            offset = 0
            phase = .idle
            return
        }
        guard phase == .idle || phase == .resetting else { return }
        runCycle()
    }

    private func runCycle() {
        guard shouldScroll else { return }
        phase = .pauseBeforeScroll
        // 停在开头 0.7s（让用户看到开头）
        withAnimation(.easeInOut(duration: 0.001)) { offset = 0 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard shouldScroll else { return }
            let delta = textWidth - containerWidth
            guard delta > 0 else { return }
            phase = .scrolling
            // 滚到末尾：duration 与 delta 成比例，约 60pt/s
            let duration = max(0.5, Double(delta) / 60.0)
            withAnimation(.linear(duration: duration)) {
                offset = -delta
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard shouldScroll else { return }
                phase = .pauseAtEnd
                // 停在末尾 1.5s
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard shouldScroll else { return }
                phase = .resetting
                // 瞬间复位（无动画）
                withAnimation(.linear(duration: 0.001)) { offset = 0 }
                try? await Task.sleep(nanoseconds: 50_000_000)
                runCycle()
            }
        }
    }
}
