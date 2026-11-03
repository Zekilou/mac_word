import SwiftUI
import AppKit

// ============================================================================
// LayoutLab —— 看板卡片布局对比（动画稳定版）
//
//     tools/layout-lab/build.sh --run      （约 4 秒）
//
// ⚠️ 上一版动画「一直在被频繁触发」的根因（重要，别再踩）：
//
//   滚动条振荡死循环：
//     列数变化 → 内容高度变化 → ScrollView 滚动条出现/消失
//     → 可用宽度变化 ~15pt → 列数又变化 → 高度又变化 → …
//
//   叠加两个放大器：
//     · 宽度是在**被滚动的内容自己身上**测的（内容宽度随滚动条抖动）
//     · `.contentTransition(.numericText())` 让每个数字变化都再起一段动画
//
//   本版的三条修法：
//     1. **宽度只在 ScrollView 外面测一次**，滚动条不影响它。
//     2. **迟滞（hysteresis）**：列数切换需要跨过 24pt 的死区，
//        小抖动不改变列数，循环被切断。
//     3. 去掉 contentTransition；动画只在列数**真的变化**时触发一次。
//
//   界面右上角有「动画触发次数」计数器，稳定时应只在你拖窗口跨过断点时 +1。
// ============================================================================

// MARK: - 宽度测量（放在滚动容器外层）

private struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 只在**不随滚动变化**的容器上测量宽度。
private struct WidthReader<Content: View>: View {
    @Binding var width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(WidthKey.self) { w in
                // @ai: 只有变化超过 1pt 才写状态，避免亚像素抖动引发重绘。
                guard w > 0, abs(w - width) > 1 else { return }
                width = w
            }
    }
}

// MARK: - 列数推导（带迟滞）

/// 由宽度推导列数，**带迟滞**：切换需要跨过 24pt 死区。
/// @ai: 没有迟滞的话，滚动条 ±15pt 的抖动会在两个列数之间反复横跳，
///      配合动画就是「一直闪」。这是本次 bug 的根因。
private func columnCount(
    width: CGFloat, minCell: CGFloat, maxCell: CGFloat?, current: Int, spacing: CGFloat = 10
) -> Int {
    guard width > 0 else { return max(current, 1) }
    let hysteresis: CGFloat = 24

    let most = max(1, Int((width + spacing) / (minCell + spacing)))
    guard let maxCell else { return most }
    // 此后 maxCell 为非可选

    // 每列不超过 maxCell 所需的最少列数。
    let fewest = max(1, Int(((width + spacing) / (maxCell + spacing)).rounded(.up)))
    let target = min(most, max(fewest, 1))

    // 迟滞：若新目标与当前列数对应的「临界宽度」差距不足死区，则保持不变。
    guard target != current else { return current }
    let currentSpan = current > 0 ? (width + spacing) / CGFloat(current) - spacing : 0
    if target < current {
        // 想减少列数 → 要求单列宽度已明显超过上限
        return currentSpan > minCell + hysteresis ? target : current
    } else {
        // 想增加列数 → 要求单列宽度已明显小于上限
        return currentSpan < maxCell - hysteresis ? target : current
    }
}

// MARK: - 数据

private struct Tile: Identifiable {
    let id: String
    let label: String
    let value: String
    let icon: String
    let tint: Color
}

private let tileData: [Tile] = [
    Tile(id: "total", label: "总词数", value: "1856", icon: "rectangle.stack", tint: .secondary),
    Tile(id: "studied", label: "已学", value: "402", icon: "book.fill", tint: .accentColor),
    Tile(id: "due", label: "今日到期", value: "341", icon: "clock", tint: .orange),
    Tile(id: "done", label: "今日已复习", value: "28", icon: "checkmark.circle", tint: .green),
    Tile(id: "reviews", label: "总复习次数", value: "2914", icon: "repeat", tint: .blue),
    Tile(id: "again", label: "AGAIN 率", value: "26%", icon: "exclamationmark.triangle", tint: .red),
]

private struct DashTile: View {
    let tile: Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: tile.icon).font(.system(size: 10)).foregroundStyle(tile.tint)
                Text(tile.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(tile.value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - 动画网格

/// 宽度驱动列数的动画网格。
/// @ai: 三个关键点：
///      1. 列数存 @State，**不**用 LazyVGrid(.adaptive)（adaptive 列数不可动画）。
///      2. 只有列数真变化时才 withAnimation。
///      3. 用 columnCount(...) 的迟滞版本，避免抖动振荡。
private struct AnimatedGrid: View {
    let width: CGFloat
    let minCell: CGFloat
    let maxCell: CGFloat?
    var animated: Bool = true
    var onAnimate: () -> Void = {}

    @State private var columns: Int = 1

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                           count: max(columns, 1)),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(tileData) { DashTile(tile: $0) }
        }
        .onChange(of: width) { _, newWidth in
            let next = columnCount(width: newWidth, minCell: minCell,
                                   maxCell: maxCell, current: columns)
            guard next != columns else { return }
            if animated {
                onAnimate()
                withAnimation(.smooth(duration: 0.3)) { columns = next }
            } else {
                columns = next
            }
        }
        .onAppear {
            columns = columnCount(width: width, minCell: minCell,
                                  maxCell: maxCell, current: 1)
        }
    }
}

// MARK: - 区块

private struct DemoSection<Content: View>: View {
    let index: String
    let title: String
    let note: String
    let width: CGFloat
    let columns: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(index)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tint)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                // @ai: 不加 contentTransition，数字变化不单独起动画（那是上一版「一直在动」的帮凶）。
                Text("宽 \(Int(width)) · \(columns) 列")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(12)
        .background(Color.primary.opacity(0.025), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Gallery

struct LayoutGalleryView: View {
    /// @ai: 宽度只在最外层测一次，ScrollView 在里面 —— 滚动条不影响它。
    @State private var width: CGFloat = 0
    @State private var animated = true
    @State private var animateCount = 0

    /// 内容可用宽度（扣掉页面 padding）。
    private var contentWidth: CGFloat { max(width - 32, 0) }

    // 各方案的列数（迟滞版，与 AnimatedGrid 内部一致，仅用于标题显示）
    private var cols1: Int { columnCount(width: contentWidth, minCell: 130, maxCell: nil, current: 1) }
    private var cols2: Int { columnCount(width: contentWidth, minCell: 130, maxCell: 200, current: 1) }
    private var cols3: Int { breakpointCount(contentWidth) }

    var body: some View {
        WidthReader(width: $width) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    s1
                    s2
                    s3
                    s4
                    footer
                }
                .padding(16)
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("看板卡片布局对比")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("动画触发 \(animateCount) 次")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(animateCount > 8 ? .orange : .secondary)
                    .monospacedDigit()
                    .help("稳定状态：拖动窗口跨过断点时才 +1。若持续增长说明还在振荡。")
                Toggle("动画", isOn: $animated)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text("拖动窗口边缘 —— 四种方案同时重排。右上角计数用于确认动画没有被反复触发。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var s1: some View {
        DemoSection(index: "①", title: "adaptive 等价（无上限）",
                    note: "等价 GridItem(.adaptive(minimum: 130))：列宽不设上限，窗口越宽卡片越扁。",
                    width: contentWidth, columns: cols1) {
            AnimatedGrid(width: contentWidth, minCell: 130, maxCell: nil,
                         animated: animated) { animateCount += 1 }
        }
    }

    private var s2: some View {
        DemoSection(index: "②", title: "列宽封顶 200（推荐）",
                    note: "等价 adaptive(min: 130, max: 200)：列宽到顶改为增加列数，卡片比例恒定。",
                    width: contentWidth, columns: cols2) {
            AnimatedGrid(width: contentWidth, minCell: 130, maxCell: 200,
                         animated: animated) { animateCount += 1 }
        }
    }

    private var s3: some View {
        DemoSection(index: "③", title: "硬断点列数",
                    note: "按容器宽度硬断点（320/520/740/960/1200）。最可控，适合必须 N 列的场合。",
                    width: contentWidth, columns: cols3) {
            BreakpointGrid(width: contentWidth, animated: animated) { animateCount += 1 }
        }
    }

    private var s4: some View {
        DemoSection(index: "④", title: "弹性单行（不换行）",
                    note: "宽时一行 6 个，窄时降到 3 个再降到 2 个。适合必须单行 KPI 的看板顶部。",
                    width: contentWidth, columns: singleRowCount(contentWidth)) {
            SingleRow(width: contentWidth, animated: animated) { animateCount += 1 }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("关键实现").font(.system(size: 11, weight: .semibold))
            Text("""
            · 动画瓶颈不是 .animation()，而是列数来源：
              LazyVGrid(.adaptive) 的列数在布局阶段算出，不经过状态 → 无法补间。
            · 正确做法：测宽（在滚动容器外层）→ 带迟滞算列数 → 存 @State
              → GridItem(.flexible()) × N → 列数变化时 withAnimation。
            · 必须加迟滞：滚动条 ±15pt 抖动会造成无限振荡（上一版的 bug）。
            """)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func breakpointCount(_ w: CGFloat) -> Int {
        if w > 1200 { return 6 }
        if w > 960 { return 5 }
        if w > 740 { return 4 }
        if w > 520 { return 3 }
        if w > 320 { return 2 }
        return 1
    }

    private func singleRowCount(_ w: CGFloat) -> Int {
        w > 700 ? 6 : (w > 480 ? 3 : 2)
    }
}

// MARK: - ③ 硬断点网格

private struct BreakpointGrid: View {
    let width: CGFloat
    let animated: Bool
    var onAnimate: () -> Void = {}
    @State private var columns: Int = 3

    private var target: Int {
        if width > 1200 { return 6 }
        if width > 960 { return 5 }
        if width > 740 { return 4 }
        if width > 520 { return 3 }
        if width > 320 { return 2 }
        return 1
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                           count: max(columns, 1)),
            alignment: .leading, spacing: 10
        ) {
            ForEach(tileData) { DashTile(tile: $0) }
        }
        .onChange(of: target) { _, next in
            guard next != columns else { return }
            if animated {
                onAnimate()
                withAnimation(.smooth(duration: 0.3)) { columns = next }
            } else {
                columns = next
            }
        }
        .onAppear { columns = target }
    }
}

// MARK: - ④ 单行

private struct SingleRow: View {
    let width: CGFloat
    let animated: Bool
    var onAnimate: () -> Void = {}
    @State private var count: Int = 6

    private var target: Int { width > 700 ? 6 : (width > 480 ? 3 : 2) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tileData.prefix(count)) { t in
                DashTile(tile: t)
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: target) { _, next in
            guard next != count else { return }
            if animated {
                onAnimate()
                withAnimation(.smooth(duration: 0.3)) { count = next }
            } else {
                count = next
            }
        }
        .onAppear { count = target }
    }
}

@main
struct LayoutLabApp: App {
    var body: some Scene {
        WindowGroup("LayoutLab — 看板卡片布局对比") {
            LayoutGalleryView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 820)
    }
}
