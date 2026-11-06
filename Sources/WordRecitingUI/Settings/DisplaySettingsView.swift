import SwiftUI
import AppKit
import WordRecitingCore

/// 设置-显示（spec §4.3）：外观（跟随系统/浅色/深色）。
/// @ai: 外观即时应用 NSApp.appearance。
struct DisplaySettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                appearanceSection
            }
            .padding(Space.section)
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
            VStack(alignment: .leading, spacing: Space.m) {
                Picker("外观模式", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Text("切换后即时生效，改动全部窗口外观。")
                    .font(Type.micro).foregroundStyle(Ink.tertiary)
            }
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

    /// 设置分组：`Section` 管标题节奏、`Card` 管边界。
    /// @ai: 这四个设置页以前各有一份逐字相同的手写实现（标题 + Card + VStack），
    ///      标题字号与卡片内边距各写一遍。现在统一走设计系统组件。
    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        Section(title: title) {
            Card { content() }
        }
    }
}
