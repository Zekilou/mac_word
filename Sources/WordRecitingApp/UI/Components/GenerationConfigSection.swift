import SwiftUI

/// 生成配置共享区（设置-默认生成配置 与 创作页-生成方式 复用同一个组件）。
/// 上方 = 引擎档位选择 + API 配置选择菜单（无任何输入框，输入在设置页「API 配置」区）；
/// 下方 = 当前模型参数卡（只读）。
/// @ai: 两处必须用本组件，保证配置项完全一致；切换 API 配置行为通过 onSelectConfig 注入。
struct GenerationConfigSection: View {
    @Binding var generatorTier: GeneratorTier
    /// 全部 API 配置（列表由设置页「API 配置」区维护）。
    @Binding var apiConfigs: [APIConfig]
    /// 当前生效的 API 配置 id。
    @Binding var activeAPIConfigID: String?
    /// 选中某条 API 配置时的回调（设置页 → activateAPIConfig；创作页 → applyProviderDefaults 后激活）。
    var onSelectConfig: (APIConfig) -> Void = { _ in }
    /// 当前模型参数卡数据（调用方用 static makeParameters 或自定义构造）。
    let parameters: [ModelParameter]
    /// 引擎小标题（设置页 "默认生成引擎" / 创作页 "生成引擎"）。
    var sectionLabel: String = "生成引擎"
    /// 当前生效模型是否思考型（nil=未探测；配置变更时自动探测，设置页可手动覆盖）。
    var isThinking: Bool? = nil
    /// 词向量来源（RAG 选锚用；设置页可切换）。
    var embeddingSource: EmbeddingSource = .builtinGloVe
    /// 远端 embedding 模型名（仅 .remoteAPI 生效展示）。
    var embeddingModel: String = "nomic-embed-text"
    /// 逐词融入验证强度。
    var embeddingVerification: EmbeddingVerification = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled(sectionLabel) {
                Picker("生成引擎", selection: $generatorTier) {
                    ForEach(GeneratorTier.allCases) { tier in
                        Text(tier.rawValue).tag(tier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if generatorTier == .remote {
                apiPicker
            } else {
                Text("进程内本地引擎：模型文件在「进程内模型」区选择后使用（swift-llama-cpp 接入中）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 当前模型参数信息卡（参数 / 上下文窗口 / 采样参数）
            parameterCard
            // 生成流程说明卡（模型类型 + 融入流程 + 词向量来源 + 验证强度）
            pipelineCard
        }
    }

    // MARK: - API 配置选择菜单（无输入框）

    private var apiPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API 配置").font(.caption).foregroundStyle(.secondary)
            if apiConfigs.isEmpty {
                Text("还没有 API 配置，去「设置 → 模型 → API 配置」添加。")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Picker("API 配置", selection: Binding(
                    get: { activeAPIConfigID ?? apiConfigs[0].id },
                    set: { id in
                        if let config = apiConfigs.first(where: { $0.id == id }) {
                            onSelectConfig(config)
                        }
                    }
                )) {
                    ForEach(apiConfigs) { config in
                        Text(config.name).tag(config.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 当前模型参数卡

    private var parameterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前模型参数").font(.caption).foregroundStyle(.secondary)
            ForEach(parameters) { p in
                HStack(alignment: .top, spacing: 6) {
                    Text(p.label)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(width: 72, alignment: .leading)
                    Text(p.value)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
                .help(p.help)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 生成流程说明卡：让用户知道当前配置下模型实际怎么工作。
    /// @ai: 随配置动态——模型类型（思考型/普通）/ 融入流程（RAG 逐词）/ 词向量来源 / 验证强度。
    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("生成流程").font(.caption).foregroundStyle(.secondary)
            pipelineRow(icon: modelTypeIcon, tint: modelType == .thinking ? .orange : .secondary,
                        label: "模型类型", value: modelTypeText, help: modelTypeHelp)
            pipelineRow(icon: "arrow.triangle.branch", tint: .secondary,
                        label: "融入方式", value: embedFlowText, help: embedFlowHelp)
            pipelineRow(icon: embeddingSource == .remoteAPI ? "globe" : "internaldrive",
                        tint: embeddingSource == .remoteAPI ? .blue : .secondary,
                        label: "词向量", value: embeddingText, help: embeddingSource.help)
            pipelineRow(icon: "checkmark.seal", tint: .secondary,
                        label: "验证强度", value: embeddingVerification.label, help: embeddingVerification.help)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func pipelineRow(icon: String, tint: Color, label: String, value: String, help: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(tint)
                .frame(width: 14)
            Text(label)
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .help(help)
    }

    /// 融入流程说明：模型自选 plan-embed（按计划嵌入）/ generate-rewrite（先写后改写逐词融入）。
    private var embedFlowText: String {
        "模型自选：先写后改写（RAG 选锚逐词融入）/ 按计划嵌入（草稿不喂目标词，融合度低自动跳过）"
    }

    private var embedFlowHelp: String {
        "草稿阶段不把目标词喂给模型（省上下文）；embedding 余弦相似度选最贴合句逐词改写；低于阈值融不进去的词跳过不硬塞"
    }

    /// 词向量来源展示：内置 GloVe（3 万词离线）/ 远端模型名。
    private var embeddingText: String {
        switch embeddingSource {
        case .builtinGloVe: return "内置 GloVe（3 万高频词，离线）"
        case .remoteAPI: return "远端 \(embeddingModel)"
        }
    }

    /// 模型类型三态：thinking / plain / unknown。
    private enum ModelType { case thinking, plain, unknown }

    private var modelType: ModelType {
        switch isThinking {
        case .some(true): return .thinking
        case .some(false): return .plain
        case .none: return .unknown
        }
    }

    private var modelTypeIcon: String {
        switch modelType {
        case .thinking: return "brain.head.profile"
        case .plain: return "text.alignleft"
        case .unknown: return "questionmark.circle"
        }
    }

    private var modelTypeText: String {
        switch modelType {
        case .thinking: return "思考型模型（计划并入初始提示，单次完成思考+写作+自查）"
        case .plain: return "普通模型（走完整多轮管线）"
        case .unknown: return "模型类型未探测（配置变更时自动检测，可手动覆盖）"
        }
    }

    private var modelTypeHelp: String {
        switch modelType {
        case .thinking: return "DeepSeek V4 等思考型：不关闭思考，计划一次性并入初始 prompt，模型自行思考写作，不强制走多轮管线"
        case .plain: return "无思考模式的普通模型：维持 strategy → planning → generate → polish 多轮管线"
        case .unknown: return "尚未探测或探测失败；更换 API 配置时自动探测，设置页可手动指定"
        }
    }

    // MARK: - 参数构造（单一来源，设置页/创作页共用）

    /// 按档位构造当前模型参数卡（模型/参数量/上下文窗口 + 采样参数）。
    /// @ai: 数值为引擎/模型估算，标注说明；设置页与创作页都从这里拿，保证一致；
    ///      上下文窗口/输出上限随设置传入（用户可调，非硬编码）。
    static func makeParameters(
        tier: GeneratorTier, model: String, localPath: String?, maxWords: Int,
        contextWindow: Int = 2048, outputTokenLimit: Int? = nil
    ) -> [ModelParameter] {
        var params: [ModelParameter] = []
        switch tier {
        case .processLocal:
            let file = (localPath as NSString?)?.lastPathComponent ?? "未选择模型文件"
            params = [
                .init(label: "模型文件", value: file, help: "「设置 → 模型」中选择的 GGUF 文件"),
                .init(label: "参数量", value: parameterScale(from: file) ?? "未知",
                      help: "从模型名提取，供参考"),
                .init(label: "上下文窗口", value: "\(contextWindow) tokens",
                      help: "生成参数中可调；超出时自动压缩输入上下文"),
            ]
        case .remote:
            params = [
                .init(label: "模型", value: model.isEmpty ? "未配置" : model,
                      help: "服务地址 / API Key 见「设置 → 模型 → API 配置」"),
                .init(label: "参数量", value: parameterScale(from: model) ?? "未知",
                      help: "从模型名提取，供参考"),
                .init(label: "上下文窗口", value: "\(contextWindow) tokens",
                      help: "按设置值；超出时自动压缩输入上下文，实际以服务端为准"),
            ]
        }
        params += samplingParameters(maxWords: maxWords, outputTokenLimit: outputTokenLimit)
        return params
    }

    /// 采样参数（生成正文与自查共用说明）。
    private static func samplingParameters(maxWords: Int, outputTokenLimit: Int?) -> [ModelParameter] {
        [
            .init(label: "温度（创意度）", value: "0.7",
                  help: "生成正文的采样温度：越高越发散/有创意，越低越保守稳定"),
            .init(label: "自查温度", value: "0.3",
                  help: "规划/自查 pass 用低温，保证稳定"),
            .init(label: "最大输出", value: outputTokenLimit.map { "\($0) tokens" } ?? "自动",
                  help: "单次生成 token 上限；自动 = 目标字数×1.5+200（越大越长），设置中可固定覆盖"),
            .init(label: "目标字数", value: "\(maxWords) 词",
                  help: "提示词要求文章长度（约）"),
        ]
    }

    /// 从模型名提取参数量（匹配 "12B"/"7B"/"0.5b" 等）。
    private static func parameterScale(from model: String) -> String? {
        guard let range = model.range(
            of: #"(\d+(?:\.\d+)?)\s*[bB]"#,
            options: .regularExpression) else { return nil }
        return "\(model[range])"
    }

    private func labeled<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
