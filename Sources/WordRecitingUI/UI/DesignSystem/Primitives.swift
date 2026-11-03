import SwiftUI
import WordRecitingCore

// MARK: - 基础原语
//
// @ai: 这里的每个组件替换掉散落在 60 个文件里的内联实现。改前统计：
//      41 处手写卡片底纹、16 处 overlay/strokeBorder、44 个裸 Divider、
//      12 处各自 clipShape(Capsule())。它们长得几乎一样但差 1–2pt，
//      于是整个应用「看起来像同一个应用，又到处都不一样」。

// MARK: Chip

/// 小标签（词频带、来源、计数）。
/// @ai: 全应用唯一的胶囊标签实现。原来有 12 处各自 `Capsule()` + 不同 padding，
///      现在统一：4pt 圆角（不是全圆），水平 6 / 垂直 2，字号 micro。
struct Chip: View {
    let text: String
    var tint: Color = Ink.secondary
    /// 选中态（用于筛选 chip）。
    var selected: Bool = false
    /// 右侧计数（如 `会 82`）。
    var count: Int? = nil
    /// 可点击时传 action；nil = 纯展示。
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: Space.xxs) {
            Text(text)
                .font(Type.micro)
            if let count {
                Text("\(count)")
                    .font(Type.mono)
                    .opacity(0.75)
            }
        }
        .foregroundStyle(selected ? Ink.inverse : tint)
        .padding(.horizontal, Space.chipH)
        .padding(.vertical, Space.chipV)
        .background(selected ? tint : tint.opacity(0.12), in: .rect(cornerRadius: Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.chip)
                .strokeBorder(tint.opacity(selected ? 0 : 0.25), lineWidth: Stroke.hairline)
        )
        .contentShape(Rectangle())
    }
}

// MARK: 掌握度徽章

/// 掌握度徽章：颜色与文案全部来自 `WordMarkState`，**禁止另配颜色**。
/// @ai: 这是审计 P0「证据来源不可辨」的落点——颜色只表档位，
///      显式标记 / 模型推断用图标区分（`MasteryPresentation.sourceIcon`）。
struct WordMarkBadge: View {
    let state: WordMarkState
    /// 是否显示概率数字（背面/列表用）。
    var showBelief: Bool = false
    /// 是否是用户显式标记（用图标区分来源）。
    var explicit: Bool = false

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(Type.micro)
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, Space.chipH)
        .padding(.vertical, Space.chipV)
        .background(state.color.opacity(0.14), in: .rect(cornerRadius: Radius.chip))
        .help(helpText)
    }

    private var icon: String {
        // @ai: 来源用**图标**区分（手形=显式标记 / 波形=模型推断 / 眼睛=被动 seen），
        //      颜色只表档位——这是审计 P0「证据来源不可辨」的修法。
        MasteryPresentation.sourceIcon(explicit: explicit, hasBelief: belief != nil)
    }

    private var belief: Double? {
        if case .learning(let b) = state { return b }
        return nil
    }

    private var label: String {
        if showBelief {
            switch state {
            case .known, .unknown, .seen, .pending: return state.label
            case .learning(let b): return MasteryPresentation.percentText(b)
            }
        }
        return state.label
    }

    private var helpText: String {
        if case .learning(let b) = state { return MasteryPresentation.helpText(b) }
        return "\(state.label)（\(explicit ? "你的标记" : "模型推断")）"
    }
}

// MARK: 点

/// 状态圆点（列表行首用）。
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

// MARK: 分隔线

/// 分隔线。
/// @ai: 替代 44 处裸 `Divider()`——原生 Divider 的粗细/缩进不可控，
///      且在 `.bar` 材质上会显出一条亮边。这里统一 1px + 可控缩进。
struct Rule: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal
    /// 左侧缩进（列表行对齐文字）。
    var inset: CGFloat = 0

    var body: some View {
        switch axis {
        case .horizontal:
            Rectangle()
                .fill(Surface.separator)
                .frame(height: Stroke.hairline)
                .padding(.leading, inset)
        case .vertical:
            Rectangle()
                .fill(Surface.separator)
                .frame(width: Stroke.hairline)
        }
    }
}

// MARK: 键盘提示

/// 快捷键提示（⌘F、1–4 这类）。
struct KeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Ink.tertiary)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 1)
            .background(Ink.primary.opacity(0.06), in: .rect(cornerRadius: 3))
    }
}
