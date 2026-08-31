import SwiftUI
import AppKit

/// 设置-显示（spec §4.3）：外观（跟随系统/浅色/深色）+ 阅读（字号/高亮样式）+ 列表密度。
/// @ai: 外观即时应用 NSApp.appearance；阅读/密度写入 AppSettings（消费方后续迭代接入）。
struct DisplaySettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                appearanceSection
                readingSection
                densitySection
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onChange(of: settings.appearanceMode) { _, mode in
            applyAppearance(mode)
        }
        .onAppear { applyAppearance(settings.appearanceMode) }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        section("外观") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("外观模式", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Text("切换后即时生效，改动全部窗口外观。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 阅读

    private var readingSection: some View {
        section("阅读") {
            VStack(alignment: .leading, spacing: 10) {
                stepper("文章字号", value: $settings.readingFontSize, in: 10...24, step: 1)
                Picker("目标词高亮样式", selection: $settings.highlightStyle) {
                    ForEach(HighlightStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    // MARK: - 列表密度

    private var densitySection: some View {
        section("列表密度") {
            Picker("列表密度", selection: $settings.listDensity) {
                ForEach(ListDensity.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
    }

    // MARK: - 动作

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - 复用

    private func stepper(
        _ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue, specifier: "%.0f") pt")
                    .font(.body.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
            .labelsHidden()
            Spacer()
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5), lineWidth: 1))
    }
}
