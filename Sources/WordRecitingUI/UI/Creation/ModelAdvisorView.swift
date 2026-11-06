import SwiftUI
import WordRecitingCore

/// 模型顾问面板（参考 FitCheck 的 advise / minspecs / lookup 三接口）：
/// 检测本机硬件 → 给出诚实 verdict + 推荐模型/量化 → 展示模型目录各量化档
/// 及国内镜像下载链接。
/// @ai: 纯展示 + 链接跳转，无写入；用于辅助用户在"本地 LLM"配置里选模型。
struct ModelAdvisorView: View {
    let hardware = MacHardware.current
    let advisor = ModelAdvisor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                adviceCard
                catalogCard
            }
            .padding(Space.page)
        }
    }

    // MARK: - 头部：硬件信息

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("模型顾问").font(Type.title)
            HStack(spacing: Space.m) {
                Text(hardware.chipName.isEmpty ? "本机" : hardware.chipName)
                    .font(Type.caption).padding(.horizontal, Space.m).padding(.vertical, Space.xxs)
                    .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
                Text("\(hardware.totalRAMGB) GB 内存")
                    .font(Type.caption).padding(.horizontal, Space.m).padding(.vertical, Space.xxs)
                    .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
                Text(hardware.isAppleSilicon ? "Apple Silicon" : "Intel")
                    .font(Type.caption).foregroundStyle(Ink.secondary)
            }
        }
    }

    // MARK: - 推荐卡（等价 /api/advise）

    private var adviceCard: some View {
        let advice = advisor.advise(hardware: hardware)
        return Card {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("硬件评估").font(Type.section)
                Text(advice.verdict)
                    .font(Type.body)
                    .foregroundStyle(advice.verdict.hasPrefix("✅") ? .green
                                     : advice.verdict.hasPrefix("⚠️") ? .orange : .red)
                if let model = advice.recommendedModel, let quant = advice.recommendedQuant {
                    HStack(spacing: Space.m) {
                        Image(systemName: "sparkles").foregroundStyle(.yellow)
                        Text("推荐：\(model.displayName) · \(quant.quant)")
                            .font(Type.bodyEmphasis)
                        Text("\(Int(quant.fileSizeGB)) GB 文件")
                            .font(Type.caption).foregroundStyle(Ink.secondary)
                    }
                    if quant.recommended {
                        Text("官方标注为推荐甜点位")
                            .font(Type.micro).foregroundStyle(Ink.secondary)
                    }
                    // 一键填入生成器配置
                    DButton("填入本地 LLM 配置", rank: .primary, icon: "arrow.down.doc") {
                        apply(model: model, quant: quant)
                    }
                    .padding(.top, Space.xs)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: Space.l) {
            Text("内置模型目录").font(Type.section)
            ForEach(ModelCatalog.all) { model in
                modelSection(model)
            }
        }
    }

    private func modelSection(_ model: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(model.displayName).font(Type.captionEmphasis)
                Text(model.parameterScale).font(Type.caption).foregroundStyle(Ink.secondary)
                Spacer()
                DButton("镜像页", rank: .quiet, icon: "globe") {
                    openURL(HFMirror.modelPage(modelID: model.modelID))
                }
            }
            Text(model.note).font(Type.micro).foregroundStyle(Ink.secondary)
            minspecTable(model)
            downloadLinks(model)
        }
        .padding(.vertical, Space.s)
    }

    /// minspecs 表格：量化档 | 文件 | 最低内存
    private func minspecTable(_ model: ModelEntry) -> some View {
        let specs = advisor.minspecs(model: model)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("量化").font(Type.caption).foregroundStyle(Ink.secondary)
                Text("文件").font(Type.caption).foregroundStyle(Ink.secondary)
                Text("最低内存").font(Type.caption).foregroundStyle(Ink.secondary)
            }
            ForEach(specs, id: \.quant.quant) { spec in
                GridRow {
                    Text(spec.quant.quant)
                        .font(Type.caption)
                        .foregroundStyle(spec.quant.recommended ? Color.accentColor : .primary)
                        .fontWeight(spec.quant.recommended ? .semibold : .regular)
                    Text("\(String(format: "%.1f", spec.quant.fileSizeGB)) GB")
                        .font(Type.caption)
                    Text("\(spec.minRAMGB) GB")
                        .font(Type.caption)
                }
            }
        }
        .padding(.leading, Space.xs)
    }

    /// 国内镜像下载链接（hf-mirror.com）
    private func downloadLinks(_ model: ModelEntry) -> some View {
        let result = advisor.lookup(hfModelID: model.modelID)
        guard let result else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("国内镜像下载（hf-mirror.com）")
                    .font(Type.micro).foregroundStyle(Ink.tertiary)
                ForEach(result.downloads, id: \.filename) { dl in
                    // 保留原有 caption 字号（下载清单是密集列表，不随按钮正文放大）
                    DButton(rank: .quiet, action: { openURL(dl.url) }) {
                        Label(dl.filename, systemImage: "arrow.down.circle")
                            .font(Type.caption)
                    }
                }
            }
            .padding(.top, Space.xxs)
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
