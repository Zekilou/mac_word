import SwiftUI
import UniformTypeIdentifiers
import WordRecitingCore

/// 独立设置页（设置-模型）：生成方式 + 进程内模型管理（复习调度在「通用」子区）。
/// @ai: 设置即时写入 AppSettings；模型文件操作走 SettingsViewModel → ModelStore。
struct SettingsView: View {
    @State var vm: SettingsViewModel
    @State var showAdvisor = false
    @State private var showFileImporter = false
    /// 正在编辑/添加的 API 配置（sheet 呈现）。
    @State private var editingConfig: APIConfig?

    init(settings: AppSettings = .shared, store: ModelStore = ModelStore()) {
        _vm = State(initialValue: SettingsViewModel(settings: settings, store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                generationSection
                apiConfigSection
                generationParamsSection
                embeddingSection
                localModelSection
                localAgentEnhancementSection
                statusSection
            }
            .padding(Space.section)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear { vm.reload() }
    }

    // MARK: - 默认生成配置（与创作页共用同一组件：设置页持久化默认值，创作页临时覆盖）

    private var generationSection: some View {
        section("默认生成配置") {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("与创作页「生成方式」列同一组件：此处配置为默认值，创作页可临时调整；API 凭据在下方「API 配置」区管理。")
                    .font(Type.caption).foregroundStyle(Ink.secondary)
                GenerationConfigSection(
                    generatorTier: Binding(
                        get: { vm.settings.generatorTier },
                        set: { vm.settings.generatorTier = $0 }),
                    apiConfigs: Binding(
                        get: { vm.settings.apiConfigs },
                        set: { vm.settings.apiConfigs = $0 }),
                    activeAPIConfigID: Binding(
                        get: { vm.settings.activeAPIConfigID },
                        set: { vm.settings.activeAPIConfigID = $0 }),
                    onSelectConfig: { vm.settings.activateAPIConfig(id: $0.id) },
                    parameters: GenerationConfigSection.makeParameters(
                        tier: vm.settings.generatorTier,
                        model: vm.settings.activeAPIConfig.model,
                        localPath: vm.settings.localModelPath,
                        maxWords: vm.settings.defaultArticleLength,
                        contextWindow: vm.settings.contextWindow,
                        outputTokenLimit: vm.settings.maxOutputTokens > 0
                            ? vm.settings.maxOutputTokens : nil),
                    sectionLabel: "默认生成引擎",
                    isThinking: vm.settings.activeAPIConfig.isThinking,
                    embeddingSource: vm.settings.embeddingSource,
                    embeddingModel: vm.settings.embeddingModel,
                    embeddingVerification: vm.settings.embeddingVerification)
                advisorSection
            }
        }
    }

    // MARK: - API 配置管理（独立区：增删改，设为当前生效）

    private var apiConfigSection: some View {
        section("API 配置") {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("维护远端 API 配置（多条）；默认生成配置区从本列表选择生效项。")
                    .font(Type.caption).foregroundStyle(Ink.secondary)
                ForEach(vm.settings.apiConfigs) { config in
                    let isActive = config.id == vm.settings.activeAPIConfigID
                    HStack(spacing: Space.m) {
                        Button {
                            vm.settings.activateAPIConfig(id: config.id)
                            vm.probeActiveConfig()
                        } label: {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("设为当前生效")
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            HStack(spacing: Space.s) {
                                Text(config.name).font(Type.body)
                                Text(config.provider.rawValue)
                                    .font(Type.micro)
                                    .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                                    .background(.quaternary.opacity(0.4))
                                    .clipShape(Capsule())
                                // 模型类型徽标（探测结果/手动覆盖）
                                Text(config.isThinking == true ? "思考型" : (config.isThinking == false ? "普通" : "未探测"))
                                    .font(Type.micro)
                                    .foregroundStyle(config.isThinking == true ? .orange : .secondary)
                                    .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                                    .background(config.isThinking == true ? AnyShapeStyle(Color.orange.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.4)))
                                    .clipShape(Capsule())
                            }
                            Text("\(config.model) · \(config.baseURL)")
                                .font(Type.caption).foregroundStyle(Ink.secondary).lineLimit(1)
                        }
                        Spacer()
                        // 手动覆盖模型类型（探测不准时兜底）
                        Picker("类型", selection: Binding(
                            get: { config.isThinking },
                            set: { newValue in
                                var edited = config
                                edited.isThinking = newValue
                                vm.settings.upsertAPIConfig(edited)
                            }
                        )) {
                            Text("自动/未探测").tag(Bool?.none)
                            Text("思考型").tag(Bool?.some(true))
                            Text("普通型").tag(Bool?.some(false))
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: Size.fieldLabel)
                        .help("模型类型：思考型把计划并入初始提示单次完成；配置变更时自动探测，可在此手动覆盖")
                        DButton("编辑", rank: .quiet) { editingConfig = config }
                        IconButton(
                            icon: "trash",
                            help: "删除（至少保留一条）",
                            disabled: vm.settings.apiConfigs.count <= 1,
                            tint: .red
                        ) {
                            vm.settings.removeAPIConfig(id: config.id)
                        }
                    }
                    .padding(.vertical, Space.xxs)
                }
                DButton("添加 API 配置", rank: .secondary, icon: "plus") {
                    editingConfig = APIConfig(
                        id: UUID().uuidString, name: "新配置",
                        provider: .ollama, model: RemoteProvider.ollama.defaultModel,
                        baseURL: RemoteProvider.ollama.defaultBaseURL, apiKey: "")
                }
            }
        }
        .sheet(item: $editingConfig) { config in
            APIConfigEditor(config: config) { edited in
                vm.settings.upsertAPIConfig(edited)
                vm.probeActiveConfig()
            }
        }
    }

    // MARK: - 生成参数

    private var generationParamsSection: some View {
        section("生成参数") {
            VStack(alignment: .leading, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("逐词融入验证强度").font(Type.caption).foregroundStyle(Ink.secondary)
                    Picker("验证强度", selection: Binding(
                        get: { vm.settings.embeddingVerification },
                        set: { vm.settings.embeddingVerification = $0 }
                    )) {
                        ForEach(EmbeddingVerification.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    Text("轻量适合本地小模型（少调用）；严格适合云端 API / 大模型。")
                        .font(Type.micro).foregroundStyle(Ink.tertiary)
                }

                Rule()

                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Text("上下文窗口").font(Type.caption).foregroundStyle(Ink.secondary)
                        Spacer()
                        Stepper("\(vm.settings.contextWindow) tokens", value: Binding(
                            get: { vm.settings.contextWindow },
                            set: { vm.settings.contextWindow = $0 }
                        ), in: 512...32768, step: 512)
                            .font(Type.caption)
                    }
                    Text("模型上下文窗口。本地 llama.cpp 默认 2048；远端按模型调大（qwen2.5~32K / gpt-4o~128K）。超出时自动压缩输入上下文。")
                        .font(Type.micro).foregroundStyle(Ink.tertiary)
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Text("输出上限").font(Type.caption).foregroundStyle(Ink.secondary)
                        Spacer()
                        Stepper(vm.settings.maxOutputTokens == 0 ? "自动" : "\(vm.settings.maxOutputTokens) tokens",
                                value: Binding(
                                    get: { vm.settings.maxOutputTokens },
                                    set: { vm.settings.maxOutputTokens = $0 }
                                ), in: 0...8192, step: 256)
                            .font(Type.caption)
                    }
                    Text("单次生成 token 上限。0 = 自动按目标字数×1.5+200 动态计算（字数越大自动加大，不再截断长文章）。")
                        .font(Type.micro).foregroundStyle(Ink.tertiary)
                }

                Rule()

                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("Agent 管线（sidecar）", isOn: Binding(
                        get: { vm.settings.useAgentSidecar },
                        set: { vm.settings.useAgentSidecar = $0 }
                    ))
                    .font(Type.caption)
                    Text("远端生成走 OpenAI Agents SDK 编排（guardrail 拦截坏输出 + 覆盖校验 + 自动修正）。开启后需重启生效；sidecar 缺失/出错自动回退普通管线。")
                        .font(Type.micro).foregroundStyle(Ink.tertiary)
                }
            }
        }
    }

    // MARK: - 词向量来源（RAG 选锚）

    private var embeddingSection: some View {
        section("词向量来源") {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("生成文章时用 embedding 余弦相似度选锚点句（RAG 按需查询，草稿不喂目标词）。")
                    .font(Type.caption).foregroundStyle(Ink.secondary)
                Picker("词向量来源", selection: Binding(
                    get: { vm.settings.embeddingSource },
                    set: { vm.settings.embeddingSource = $0 }
                )) {
                    ForEach(EmbeddingSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Text(vm.settings.embeddingSource.help)
                    .font(Type.micro).foregroundStyle(Ink.tertiary)
                if vm.settings.embeddingSource == .remoteAPI {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("远端模型名").font(Type.caption).foregroundStyle(Ink.secondary)
                        TextField("如 nomic-embed-text", text: Binding(
                            get: { vm.settings.embeddingModel },
                            set: { vm.settings.embeddingModel = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        Text("服务地址与 API Key 复用上方「API 配置」当前生效项；Ollama 需先 `ollama pull nomic-embed-text`。")
                            .font(Type.micro).foregroundStyle(Ink.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - 进程内模型

    private var localModelSection: some View {
        section("进程内模型") {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("模型文件目录：\(vm.store.modelsDirectory.path)")
                    .font(Type.micro)
                    .foregroundStyle(Ink.tertiary)
                    .textSelection(.enabled)

                HStack(spacing: Space.m) {
                    DButton("选择 GGUF 文件", rank: .secondary, icon: "folder") {
                        showFileImporter = true
                    }
                    .fileImporter(
                        isPresented: $showFileImporter,
                        allowedContentTypes: [.data],
                        allowsMultipleSelection: false
                    ) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            vm.importModel(from: url)
                        }
                    }
                    IconButton(icon: "arrow.clockwise", help: "刷新") {
                        vm.reload()
                    }
                    Spacer()
                    Text("下载新模型见下方「一键下载」")
                        .font(Type.micro).foregroundStyle(Ink.tertiary)
                }

                if vm.localModels.isEmpty {
                    Text("还没有模型文件。选择 GGUF 文件，或从下方 Ollama 一键提取。")
                        .font(Type.caption).foregroundStyle(Ink.secondary)
                } else {
                    modelList
                }

                ollamaSection
                downloadSection
            }
        }
    }

    private var modelList: some View {
        VStack(spacing: Space.xxs) {
            ForEach(vm.localModels) { model in
                let isSelected = vm.settings.localModelPath == model.url.path
                ListRow(selected: isSelected, action: { vm.selectModel(model) }) {
                    HStack(spacing: Space.m) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(model.fileName)
                            .font(Type.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(model.sizeDescription)
                            .font(Type.caption).foregroundStyle(Ink.secondary)
                    }
                }
            }
            if let path = vm.settings.localModelPath, !vm.settings.localModelPathIsUsable {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("已选模型文件不存在：\(path)。请在下方列表重新选择。")
                        .font(Type.caption)
                        .foregroundStyle(Ink.secondary)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.vertical, Space.xs)
            }
        }
    }

    private var ollamaSection: some View {
        DisclosureGroup {
            if vm.ollamaCandidates.isEmpty {
                Text("未检测到 Ollama 模型（需先 `ollama pull`）。")
                    .font(Type.caption).foregroundStyle(Ink.secondary)
            } else {
                VStack(spacing: Space.xxs) {
                    ForEach(vm.ollamaCandidates) { candidate in
                        HStack(spacing: Space.m) {
                            Text(candidate.fullName)
                                .font(Type.body)
                                .lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: candidate.sizeBytes, countStyle: .file))
                                .font(Type.caption).foregroundStyle(Ink.secondary)
                            DButton("提取为 GGUF", rank: .secondary) {
                                vm.extractOllama(candidate)
                            }
                        }
                        .padding(.vertical, Space.xxs)
                    }
                }
            }
        } label: {
            Label("从 Ollama 提取已下载模型（转为进程内 GGUF）", systemImage: "tray.and.arrow.down")
                .font(Type.caption)
        }
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("从国内镜像 hf-mirror.com 直接下载到模型目录，完成后自动选中。")
                .font(Type.caption).foregroundStyle(Ink.secondary)
            ForEach(ModelCatalog.all) { entry in
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("\(entry.displayName)（\(entry.parameterScale)）— \(entry.note)")
                        .font(Type.caption)
                    HStack(spacing: Space.m) {
                        ForEach(entry.quants) { quant in
                            DButton(
                                "\(quant.quant) \(String(format: "%.1f", quant.fileSizeGB))GB",
                                rank: .secondary,
                                help: quant.recommended ? "推荐档（\(quant.fileName)）" : quant.fileName,
                                disabled: vm.downloadActivityID != nil
                            ) {
                                vm.downloadModel(entry, quant: quant)
                            }
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, Space.xs)
            }
            // 下载状态读全局活动中心（切页/返回设置页仍可见）
            if let dl = GlobalActivityCenter.shared.items.first(where: { $0.tag == "download" }) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.m) {
                        Text("下载：\(dl.title)")
                            .font(Type.caption)
                        Spacer()
                        if vm.downloadPaused {
                            DButton("继续", rank: .quiet) { vm.resumeDownload() }
                        } else {
                            DButton("暂停", rank: .quiet) { vm.pauseDownload() }
                        }
                        DButton("取消", rank: .quiet) { vm.cancelDownload() }
                    }
                    ProgressView(value: dl.progress ?? 0)
                        .progressViewStyle(.linear)
                    HStack(spacing: Space.m) {
                        if let msg = dl.message {
                            Text(msg).font(Type.micro).foregroundStyle(Ink.tertiary)
                        }
                        if let bytes = dl.bytes {
                            Text("\(ByteCountFormatter.string(fromByteCount: bytes.received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: bytes.total, countStyle: .file))")
                                .font(Type.micro).foregroundStyle(Ink.tertiary)
                        }
                    }
                }
                .padding(.top, Space.xs)
            }
        }
    }

    // MARK: - 本地 agent 增强（进程内档走 sidecar 框架，复用 guardrail + 自动修正）

    /// 仅当默认生成档位为进程内本地时显示。
    @ViewBuilder
    private var localAgentEnhancementSection: some View {
        if vm.settings.generatorTier == .processLocal {
            section("本地 agent 增强") {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text("启用后进程内本地档改走 sidecar 框架（OpenAI Agents SDK 编排：guardrail 拦截 + 自动修正循环），复用远端同款鲁棒性。需先下载 llama-server 二进制（约 10-20MB），不可用时自动回退 LocalLLMGenerator。")
                        .font(Type.caption).foregroundStyle(Ink.secondary)

                    Toggle("启用本地 agent 增强", isOn: Binding(
                        get: { vm.settings.useLocalAgentEnhancement },
                        set: { vm.settings.useLocalAgentEnhancement = $0 }))

                    // llama-server 二进制状态
                    if vm.llamaServerBinaryReady {
                        HStack(spacing: Space.m) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("llama-server 已就绪").font(Type.caption)
                            Spacer()
                            DButton("检查更新", rank: .secondary) {
                                Task { await vm.checkLatestLlamaServer() }
                            }
                            DButton("重新下载", rank: .secondary) { vm.downloadLlamaServer() }
                        }
                    } else {
                        HStack(spacing: Space.m) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("未下载 llama-server 二进制（内置版本 \(LlamaServerRelease.fallbackTag)）").font(Type.caption)
                            Spacer()
                            DButton("下载", rank: .primary, icon: "arrow.down.circle") {
                                vm.downloadLlamaServer()
                            }
                        }
                    }

                    // 生命周期配置
                    Picker("进程生命周期", selection: Binding(
                        get: { vm.settings.llamaServerLifecycle },
                        set: { vm.settings.llamaServerLifecycle = $0 })) {
                        ForEach(LlamaServerLifecycle.allCases) { lifecycle in
                            Text(lifecycle.label).tag(lifecycle)
                        }
                    }

                    // 进程状态 + 启动/停止（手动控制）
                    HStack(spacing: Space.m) {
                        switch vm.llamaServerStatus {
                        case .stopped:
                            Image(systemName: "circle").foregroundStyle(Ink.secondary)
                            Text("已停止").font(Type.caption)
                        case .starting:
                            Image(systemName: "circle.dotted").foregroundStyle(.orange)
                            Text("启动中…").font(Type.caption)
                        case .running(let port):
                            Image(systemName: "circle.fill").foregroundStyle(.green)
                            Text("运行中（端口 \(port)）").font(Type.caption)
                        case .failed(let msg):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text("失败：\(msg)").font(Type.caption).lineLimit(1)
                        }
                        Spacer()
                        if vm.llamaServerIsRunning {
                            DButton("停止", rank: .secondary) { vm.stopLlamaServer() }
                        } else {
                            DButton(
                                "启动",
                                rank: .secondary,
                                disabled: !vm.llamaServerBinaryReady || vm.settings.localModelPath == nil
                            ) {
                                Task { await vm.startLlamaServer() }
                            }
                        }
                    }
                    .onChange(of: vm.settings.llamaServerLifecycle) { _, _ in
                        Task { await vm.applyLifecycleChange() }
                    }
                }
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let msg = vm.statusMessage {
                Text(msg).font(Type.caption).foregroundStyle(.green)
            }
            if let err = vm.errorMessage {
                Text(err).font(Type.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 复用

    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(title).font(Type.section)
                content()
            }
        }
    }
}

// MARK: - API 配置编辑表单

/// 添加/编辑一条 API 配置（名称 + 提供商 + 模型 + 地址 + Key）。
/// @ai: 保存走回调（AppSettings.upsertAPIConfig）；不改裸 defaults。
struct APIConfigEditor: View {
    let config: APIConfig
    let onSave: (APIConfig) -> Void
    @State private var name: String
    @State private var provider: RemoteProvider
    @State private var model: String
    @State private var baseURL: String
    @State private var apiKey: String
    @Environment(\.dismiss) private var dismiss

    init(config: APIConfig, onSave: @escaping (APIConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        _name = State(initialValue: config.name)
        _provider = State(initialValue: config.provider)
        _model = State(initialValue: config.model)
        _baseURL = State(initialValue: config.baseURL)
        _apiKey = State(initialValue: config.apiKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(config.name.isEmpty ? "添加 API 配置" : "编辑 API 配置")
                .font(Type.section)
            TextField("配置名称（如：本地 Ollama）", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("提供商", selection: $provider) {
                ForEach(RemoteProvider.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: provider) { _, newValue in
                model = newValue.defaultModel
                baseURL = newValue.defaultBaseURL
                if !newValue.needsAPIKey { apiKey = "" }
            }
            TextField("模型名", text: $model)
                .textFieldStyle(.roundedBorder)
            TextField("服务地址", text: $baseURL)
                .textFieldStyle(.roundedBorder)
            if provider.needsAPIKey {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            Text(provider.hint)
                .font(Type.micro).foregroundStyle(Ink.tertiary)
            HStack {
                Spacer()
                DButton("取消", rank: .secondary) { dismiss() }
                DButton(
                    "保存",
                    rank: .primary,
                    disabled: name.trimmingCharacters(in: .whitespaces).isEmpty || model.isEmpty
                ) {
                    onSave(APIConfig(
                        id: config.id, name: name.trimmingCharacters(in: .whitespaces),
                        provider: provider, model: model, baseURL: baseURL, apiKey: apiKey,
                        isThinking: config.isThinking))
                    dismiss()
                }
            }
        }
        .padding(Space.page)
        .frame(width: Size.sidebarPanel)
    }
}
