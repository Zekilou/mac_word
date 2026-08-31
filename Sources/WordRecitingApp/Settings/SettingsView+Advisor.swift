import SwiftUI

// MARK: - 设置页：模型顾问（检测硬件并推荐模型/量化档，应用推荐到当前模型）

extension SettingsView {

    /// 模型顾问：硬件检测 + 推荐模型/量化档 + 一键应用到 llmModel（远端配置区下方）。
    var advisorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showAdvisor = true } label: {
                Label("模型顾问：检测硬件并推荐", systemImage: "cpu")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text("按你的内存推荐模型与量化档")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .sheet(isPresented: $showAdvisor) {
            ModelAdvisorView()
                .frame(width: 520, height: 560)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelAdvisorApply)) { note in
            if let info = note.userInfo,
               let modelID = info["modelID"] as? String,
               let quant = info["quant"] as? String {
                // 应用到当前生效的 API 配置（同步模型字段，保持 apiConfigs 一致）
                let modelName = "\(modelID) (\(quant))"
                vm.settings.llmModel = modelName
                var config = vm.settings.activeAPIConfig
                config.model = modelName
                vm.settings.upsertAPIConfig(config)
                showAdvisor = false
            }
        }
    }
}
