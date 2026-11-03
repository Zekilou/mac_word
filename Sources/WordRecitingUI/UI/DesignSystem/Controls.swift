import SwiftUI
import WordRecitingCore

// MARK: - 控件组件
//
// @ai: 按钮/输入/选择器在各页的写法差异最大：同样是「主按钮」，
//      有的 `.borderedProminent`、有的自绘圆角矩形、有的 `.bordered`；
//      同样是工具栏图标按钮，padding 在 4/6/8 之间乱跳。这里统一。

// MARK: 按钮

/// 按钮层级。
/// @ai: 只有三档。再多就会出现「两个都像是主按钮」的界面——这是层级混乱的起点。
enum ButtonRank {
    /// 主操作：一屏最多一个。
    case primary
    /// 次要操作。
    case secondary
    /// 工具栏图标 / 行内小操作。
    case quiet
    /// 破坏性操作。
    case destructive
}

/// 统一按钮。
struct DButton<Label: View>: View {
    let rank: ButtonRank
    var icon: String? = nil
    var help: String? = nil
    var fullWidth: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11))
                }
                label()
            }
            .font(Type.emphasis)
            .foregroundStyle(foreground)
            .padding(.horizontal, Space.rowH)
            .padding(.vertical, Space.rowV)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background, in: .rect(cornerRadius: Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(border, lineWidth: Stroke.hairline)
            )
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .help(help ?? "")
    }

    private var foreground: Color {
        switch rank {
        case .primary: return Ink.inverse
        case .destructive: return .red
        case .secondary, .quiet: return Ink.primary
        }
    }

    private var background: Color {
        switch rank {
        case .primary:
            return Color.accentColor.opacity(hovering ? 1 : 0.92)
        case .destructive:
            return Color.red.opacity(hovering ? 0.16 : 0.10)
        case .secondary:
            return Ink.primary.opacity(hovering ? 0.10 : 0.06)
        case .quiet:
            return hovering ? Ink.primary.opacity(0.07) : .clear
        }
    }

    private var border: Color {
        switch rank {
        case .primary: return .clear
        case .destructive: return Color.red.opacity(0.22)
        case .secondary: return Ink.primary.opacity(0.10)
        case .quiet: return .clear
        }
    }
}

extension DButton where Label == Text {
    /// 纯文字按钮。
    init(_ title: String, rank: ButtonRank = .secondary, icon: String? = nil,
         help: String? = nil, fullWidth: Bool = false, disabled: Bool = false,
         action: @escaping () -> Void) {
        self.init(rank: rank, icon: icon, help: help, fullWidth: fullWidth,
                  disabled: disabled, action: action) { Text(title) }
    }
}

/// 工具栏图标按钮（替代各页裸 `Button { Image(systemName:) }.buttonStyle(.borderless)`）。
struct IconButton: View {
    let icon: String
    var help: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? Ink.primary : Ink.secondary)
                .frame(width: 24, height: 24)
                .background(
                    hovering ? Ink.primary.opacity(0.07) : .clear,
                    in: .rect(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .help(help ?? "")
    }
}

// MARK: 输入

/// 单行输入框。
struct DTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var monospaced: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? Type.monoBody : Type.body)
                .focused($focused)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Surface.field, in: .rect(cornerRadius: Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(focused ? Color.accentColor.opacity(0.6)
                                      : Surface.separator,
                              lineWidth: Stroke.hairline)
        )
    }
}

// MARK: 选择器

/// 分段选择器（替代 `.pickerStyle(.segmented)`——原生控件在密集界面里过高且边距不可控）。
struct SegmentedChoice<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = selection == opt.value
                Button {
                    selection = opt.value
                } label: {
                    Text(opt.label)
                        .font(Type.micro)
                        .foregroundStyle(on ? Ink.primary : Ink.secondary)
                        .padding(.horizontal, compact ? Space.m : Space.l)
                        .padding(.vertical, compact ? 3 : Space.xs)
                        .frame(maxWidth: .infinity)
                        .background(
                            on ? Surface.card : .clear,
                            in: .rect(cornerRadius: Radius.chip))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Ink.primary.opacity(0.05), in: .rect(cornerRadius: Radius.control))
    }
}

// MARK: 设置行

/// 设置项行：标题 + 说明 + 右侧控件。
/// @ai: 设置页有 4 个子区、约 40 个设置项，每项都是「标题 / 说明 / 控件」三件套，
///      却各写一遍标签宽度与说明字号。统一后整个设置区的节奏才一致。
struct SettingRow<Control: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Type.emphasis)
                if let note {
                    Text(note)
                        .font(Type.caption)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, Space.s)
    }
}

// MARK: 分节标题

/// 小标题（用于一屏内的次级分组）。
struct Subhead: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Type.micro.weight(.semibold))
            .foregroundStyle(Ink.tertiary)
            .textCase(.uppercase)
    }
}

// MARK: 错误条

/// 行内错误提示。
/// @ai: 原来各页把错误写成 `Text(err).font(.caption).foregroundStyle(.red)`，
///      位置、缩进、背景各不相同（有的在工具条下、有的浮在顶部、有的挤在按钮旁）。
struct InlineError: View {
    let message: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(message)
                .font(Type.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                IconButton(icon: "xmark", help: "关闭", action: onDismiss)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: Radius.control))
    }
}
