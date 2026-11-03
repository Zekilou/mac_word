import SwiftUI
import WordRecitingCore

// MARK: - 数据展示组件
//
// @ai: 替换 HomeView 的 KPI 卡与分析页 statCard 两套实现（它们本该是同一个东西）。

// MARK: 统计块

/// 统计卡：看板上的一个指标。
/// @ai: 这是**全应用唯一的统计卡**。此前 HomeView.kpiCard 与 AnalyticsView.statCard
///      是两份实现（图标大小、背景透明度、圆角都不同），同一屏里出现两种统计卡。
///      数字用等宽体（`Type.statValue`）——否则 9→10 时整行抖动。
struct StatTile: View {
    let label: String
    let value: String
    var icon: String? = nil
    var tint: Color = Ink.secondary
    /// 数值下方的补充说明。
    var note: String? = nil
    /// 点击（可选）。有 action 时显示 hover 反馈。
    var action: (() -> Void)? = nil
    /// 强调样式（首页主 KPI 用，数字更大）。
    var emphasis: Bool = false

    @State private var hovering = false

    var body: some View {
        content
            .onHover { hovering = action != nil && $0 }
    }

    @ViewBuilder
    private var content: some View {
        let card = VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(IconSize.inline)
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(Type.micro)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(emphasis ? Type.statValueLarge : Type.statValue)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let note {
                Text(note)
                    .font(Type.micro)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            hovering ? Surface.card : Surface.card.opacity(0.55),
            in: .rect(cornerRadius: Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(Surface.separator, lineWidth: Stroke.hairline))
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }
}

// MARK: 看板网格

/// 统一的看板网格。
/// @ai: 全应用所有「一排指标卡」都走这里，不再各写 LazyVGrid。
///      用 `.adaptive(minimum:)` 而**不给 maximum**——这是与用户确认过的视觉：
///      卡片随窗口自然拉伸，列数自适应。想要列宽封顶就传 `maxCell`。
struct DashboardGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    /// 卡片最小宽度（见 `GridMetrics`）。
    var minCell: CGFloat = GridMetrics.statMin
    /// 卡片最大宽度；nil = 不封顶（默认，随窗口拉伸）。
    var maxCell: CGFloat? = nil
    var spacing: CGFloat = Space.m
    @ViewBuilder let cell: (Item) -> Cell

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minCell, maximum: maxCell ?? .infinity),
                  spacing: spacing)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            ForEach(items) { cell($0) }
        }
    }
}

// MARK: 进度条

/// 进度条：可控高度与配色（替代裸 ProgressView 在密集界面里过硬的问题）。
struct Meter: View {
    let value: Double
    var total: Double = 1
    var tint: Color = .accentColor
    var height: CGFloat = 5

    private var ratio: Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * ratio))
            }
        }
        .frame(height: height)
    }
}

// MARK: 分段进度条

/// 多段进度条（会 / 学习中 / 不会 的比例条）。
/// @ai: 分析页与首页都要「一档一条不同颜色」的分布条，旧实现各自拼 HStack + 多个 Rectangle。
struct SegmentedMeter: View {
    let segments: [(value: Double, color: Color)]
    var height: CGFloat = 6

    private var total: Double { max(segments.reduce(0) { $0 + $1.value }, 0.0001) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    let w = geo.size.width * (seg.value / total)
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: max(0, w))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .background(Ink.primary.opacity(0.08), in: .capsule)
    }
}

// MARK: 键值行

/// 键值行（右侧详情面板、设置项）。
struct KeyValueRow: View {
    let key: String
    let value: String
    var valueColor: Color = Ink.primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            Text(key)
                .font(Type.caption)
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: Space.m)
            Text(value)
                .font(Type.caption)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: 音标

/// 音标展示。
struct Phonetic: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Ink.secondary)
            .textSelection(.disabled)
    }
}
