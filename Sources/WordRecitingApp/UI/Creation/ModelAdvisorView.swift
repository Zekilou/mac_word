import SwiftUI

/// 模型顾问面板（参考 FitCheck 的 advise / minspecs / lookup 三接口）：
/// 检测本机硬件 → 给出诚实 verdict + 推荐模型/量化 → 展示模型目录各量化档
/// 及国内镜像下载链接。
/// @ai: 纯展示 + 链接跳转，无写入；用于辅助用户在"本地 LLM"配置里选模型。
struct ModelAdvisorView: View {
    let hardware = MacHardware.current
    let advisor = ModelAdvisor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                adviceCard
                catalogCard
            }
            .padding(16)
        }
    }

    // MARK: - 头部：硬件信息

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("模型顾问").font(.title2).fontWeight(.semibold)
            HStack(spacing: 8) {
                Text(hardware.chipName.isEmpty ? "本机" : hardware.chipName)
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
                Text("\(hardware.totalRAMGB) GB 内存")
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
                Text(hardware.isAppleSilicon ? "Apple Silicon" : "Intel")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 推荐卡（等价 /api/advise）

    private var adviceCard: some View {
        let advice = advisor.advise(hardware: hardware)
        return VStack(alignment: .leading, spacing: 8) {
            Text("硬件评估").font(.headline)
            Text(advice.verdict)
                .font(.body)
                .foregroundStyle(advice.verdict.hasPrefix("✅") ? .green
                                 : advice.verdict.hasPrefix("⚠️") ? .orange : .red)
            if let model = advice.recommendedModel, let quant = advice.recommendedQuant {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.yellow)
                    Text("推荐：\(model.displayName) · \(quant.quant)")
                        .font(.body).fontWeight(.semibold)
                    Text("\(Int(quant.fileSizeGB)) GB 文件")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if quant.recommended {
                    Text("官方标注为推荐甜点位")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                // 一键填入生成器配置
                Button {
                    apply(model: model, quant: quant)
                } label: {
                    Label("填入本地 LLM 配置", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 把推荐模型 ID / 量化档写入生成器的 LLM 配置。
    private func apply(model: ModelEntry, quant: QuantOption) {
        NotificationCenter.default.post(
            name: .modelAdvisorApply,
            object: nil,
            userInfo: ["modelID": model.modelID, "quant": quant.quant])
    }

    // MARK: - 目录卡（等价 /api/lookup + /api/minspecs + 镜像下载）

    private var catalogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内置模型目录").font(.headline)
            ForEach(ModelCatalog.all) { model in
                modelSection(model)
            }
        }
    }

    private func modelSection(_ model: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.displayName).font(.subheadline).fontWeight(.semibold)
                Text(model.parameterScale).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    openURL(HFMirror.modelPage(modelID: model.modelID))
                } label: {
                    Label("镜像页", systemImage: "globe")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            Text(model.note).font(.caption2).foregroundStyle(.secondary)
            minspecTable(model)
            downloadLinks(model)
        }
        .padding(.vertical, 6)
    }

    /// minspecs 表格：量化档 | 文件 | 最低内存
    private func minspecTable(_ model: ModelEntry) -> some View {
        let specs = advisor.minspecs(model: model)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("量化").font(.caption).foregroundStyle(.secondary)
                Text("文件").font(.caption).foregroundStyle(.secondary)
                Text("最低内存").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(specs, id: \.quant.quant) { spec in
                GridRow {
                    Text(spec.quant.quant)
                        .font(.caption)
                        .foregroundStyle(spec.quant.recommended ? Color.accentColor : .primary)
                        .fontWeight(spec.quant.recommended ? .semibold : .regular)
                    Text("\(String(format: "%.1f", spec.quant.fileSizeGB)) GB")
                        .font(.caption)
                    Text("\(spec.minRAMGB) GB")
                        .font(.caption)
                }
            }
        }
        .padding(.leading, 4)
    }

    /// 国内镜像下载链接（hf-mirror.com）
    private func downloadLinks(_ model: ModelEntry) -> some View {
        let result = advisor.lookup(hfModelID: model.modelID)
        guard let result else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text("国内镜像下载（hf-mirror.com）")
                    .font(.caption2).foregroundStyle(.tertiary)
                ForEach(result.downloads, id: \.filename) { dl in
                    Button {
                        openURL(dl.url)
                    } label: {
                        Label(dl.filename, systemImage: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            .padding(.top, 2)
        )
    }

    private func openURL(_ url: String) {
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - 应用推荐通知

extension Notification.Name {
    /// 模型顾问 → GenerateView：把推荐模型填入 LLM 配置。
    static let modelAdvisorApply = Notification.Name("modelAdvisorApply")
}
