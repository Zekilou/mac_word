import SwiftUI
import WordRecitingCore

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
        VStack(alignment: .leading, spacing: Space.l) {
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
                HStack(spacing: Space.xs) {
                    Text("进程内本地引擎")
                        .font(Type.caption).foregroundStyle(Ink.secondary)
                    InfoHint(text: "模型文件在「进程内模型」区选择后使用（swift-llama-cpp 接入中）。")
                }
            }

            // 当前模型参数信息卡（参数 / 上下文窗口 / 采样参数）
            parameterCard
            // 生成流程说明卡（模型类型 + 融入流程 + 词向量来源 + 验证强度）
            pipelineCard
        }
    }

    // MARK: - API 配置选择菜单（无输入框）

    private var apiPicker: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("API 配置").font(Type.caption).foregroundStyle(Ink.secondary)
            if apiConfigs.isEmpty {
                Text("还没有 API 配置，去「设置 → 模型 → API 配置」添加。")
                    .font(Type.caption).foregroundStyle(Ink.tertiary)
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
        Panel(padding: Space.m) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("当前模型参数").font(Type.caption).foregroundStyle(Ink.secondary)
                ForEach(parameters) { p in
                    HStack(alignment: .top, spacing: Space.s) {
                        Text(p.label)
                            .font(Type.micro).foregroundStyle(Ink.tertiary)
                            .frame(width: Size.colLabel, alignment: .leading)
                        Text(p.value)
                            .font(Type.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                    .help(p.help ?? "")
                }
            }
        }
    }

    /// 生成流程摘要卡。
    /// @ai: 原来这里是 4 行 key-value（模型类型 / 融入方式 / 词向量 / 验证强度），
    ///      每行还各挂一段 tooltip，其中「融入方式」的值是一整句
    ///      「模型自选：先写后改写（RAG 选锚逐词融入）/ 按计划嵌入（草稿不喂目标词…）」。
    ///      这些是**内部实现**，用户既改不了也不需要逐项读。
    ///      现在收成一行摘要，细节全在 tooltip 里。
    private var pipelineCard: some View {
        HStack(spacing: Space.s) {
            Image(systemName: modelTypeIcon)
                .font(Type.micro)
                .foregroundStyle(modelType == .thinking ? .orange : Ink.tertiary)
            Text(pipelineSummary)
                .font(Type.micro)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            InfoHint(text: pipelineDetail)
        }
    }

    /// 一行摘要：模型类型 · 融入方式 · 词向量
    private var pipelineSummary: String {
        var parts = [modelTypeText, embedFlowShort]
        if embeddingSource == .remoteAPI { parts.append("远端向量") }
        return parts.joined(separator: " · ")
    }

    /// tooltip：完整实现细节。
    private var pipelineDetail: String {
        """
        \(modelTypeHelp)
        \(embedFlowHelp)
        词向量：\(embeddingText)（\(embeddingSource.help)）
        验证强度：\(embeddingVerification.label)（\(embeddingVerification.help)）
        """
    }

    private func pipelineRow(icon: String, tint: Color, label: String, value: String, help: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: icon).font(Type.micro).foregroundStyle(tint)
                .frame(width: Size.capsulePadding)
            Text(label)
                .font(Type.micro).foregroundStyle(Ink.tertiary)
                .frame(width: Size.colLabel, alignment: .leading)
            Text(value)
                .font(Type.micro)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .help(help)
    }

    /// 融入方式短语（列表用，一行内说完）。
    private var embedFlowShort: String {
        modelType == .thinking ? "浅管线" : "RAG 逐词"
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
            // @ai: 参数量从模型名里就能看出来（qwen2.5-0.5b），单独一行是纯噪音，
            //      已并入「模型」一项显示为 `qwen2.5-0.5b · 0.5B`，省一行。
            params = [
                .init(label: "模型",
                      value: file + (parameterScale(from: file).map { " · \($0)" } ?? "")),
                .init(label: "上下文", value: "\(contextWindow) tokens"),
            ]
        case .remote:
            params = [
                .init(label: "模型", value: model.isEmpty ? "未配置" : model),
                .init(label: "上下文", value: "\(contextWindow) tokens"),
            ]
        }
        params += samplingParameters(maxWords: maxWords, outputTokenLimit: outputTokenLimit)
        return params
    }

    /// 采样参数。
    /// @ai: 只留用户真正关心的两项。`自查温度` 是内部 pass 的实现细节，
    ///      `最大输出` 的「自动」也已足够自解释——它们原来各占一行 + 一段 tooltip，
    ///      是「只读信息列太满」的典型。要调这些值去设置页，不在这里列。
    private static func samplingParameters(maxWords: Int, outputTokenLimit: Int?) -> [ModelParameter] {
        [
            .init(label: "温度", value: "0.7",
                  help: "越高越发散，越低越稳定"),
            .init(label: "目标字数", value: "\(maxWords) 词"),
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
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(Type.caption).foregroundStyle(Ink.secondary)
            content()
        }
    }
}
