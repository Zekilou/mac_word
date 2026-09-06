import SwiftUI
import AppKit

/// 设置-显示（spec §4.3）：外观（跟随系统/浅色/深色）。
/// @ai: 外观即时应用 NSApp.appearance。
struct DisplaySettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                appearanceSection
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

    // MARK: - 动作

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - 复用

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
