import SwiftUI
import UniformTypeIdentifiers

/// 独立设置页：LLM 生成配置（持久化）+ 进程内模型管理 + 复习调度。
/// @ai: 设置即时写入 AppSettings；模型文件操作走 SettingsViewModel → ModelStore。
struct SettingsView: View {
    @State private var vm: SettingsViewModel
    @State private var showFileImporter = false

    init(settings: AppSettings = .shared, store: ModelStore = ModelStore()) {
        _vm = State(initialValue: SettingsViewModel(settings: settings, store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                generationSection
                localModelSection
                schedulingSection
                statusSection
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear { vm.reload() }
    }

    // MARK: - 生成设置

    private var generationSection: some View {
        section("生成设置") {
            VStack(alignment: .leading, spacing: 10) {
                Text("默认生成方式").font(.caption).foregroundStyle(.secondary)
                Picker("生成方式", selection: Binding(
                    get: { vm.settings.generatorTier },
                    set: { vm.settings.generatorTier = $0 }
                )) {
                    ForEach(GeneratorTier.allCases) { tier in
                        Text(tier.rawValue).tag(tier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if vm.settings.generatorTier == .remote {
                    remoteConfig
                } else {
                    Text("进程内本地引擎将在「进程内模型」区配置模型文件后使用（swift-llama-cpp 接入中）。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()
                Text("逐词融入验证强度").font(.caption).foregroundStyle(.secondary)
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
                Text("轻量适合本地小模型（少调用）；严格适合云端 API / 大模型。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var remoteConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("服务类型", selection: Binding(
                get: { vm.settings.remoteProvider },
                set: { vm.switchRemoteProvider($0) }
            )) {
                ForEach(RemoteProvider.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 6) {
                TextField("模型名", text: Binding(
                    get: { vm.settings.llmModel },
                    set: { vm.settings.llmModel = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                TextField("服务地址", text: Binding(
                    get: { vm.settings.llmBaseURL },
                    set: { vm.settings.llmBaseURL = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            if vm.settings.remoteProvider.needsAPIKey {
                SecureField("API Key", text: Binding(
                    get: { vm.settings.llmAPIKey },
                    set: { vm.settings.llmAPIKey = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Text(vm.settings.remoteProvider.hint)
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - 进程内模型

    private var localModelSection: some View {
        section("进程内模型") {
            VStack(alignment: .leading, spacing: 10) {
                Text("模型文件目录：\(vm.store.modelsDirectory.path)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("选择 GGUF 文件", systemImage: "folder")
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
                    Button {
                        vm.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("刷新")
                    Spacer()
                    Text("下载新模型见下方「一键下载」")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                if vm.localModels.isEmpty {
                    Text("还没有模型文件。选择 GGUF 文件，或从下方 Ollama 一键提取。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    modelList
                }

                ollamaSection
                downloadSection
            }
        }
    }

    private var modelList: some View {
        VStack(spacing: 2) {
            ForEach(vm.localModels) { model in
                let isSelected = vm.settings.localModelPath == model.url.path
                Button {
                    vm.selectModel(model)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(model.fileName)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(model.sizeDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var ollamaSection: some View {
        DisclosureGroup {
            if vm.ollamaCandidates.isEmpty {
                Text("未检测到 Ollama 模型（需先 `ollama pull`）。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(vm.ollamaCandidates) { candidate in
                        HStack(spacing: 8) {
                            Text(candidate.fullName)
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: candidate.sizeBytes, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                            Button("提取为 GGUF") {
                                vm.extractOllama(candidate)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } label: {
            Label("从 Ollama 提取已下载模型（转为进程内 GGUF）", systemImage: "tray.and.arrow.down")
                .font(.caption)
        }
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("从国内镜像 hf-mirror.com 直接下载到模型目录，完成后自动选中。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ModelCatalog.all) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(entry.displayName)（\(entry.parameterScale)）— \(entry.note)")
                        .font(.caption)
                    HStack(spacing: 8) {
                        ForEach(entry.quants) { quant in
                            Button {
                                vm.downloadModel(entry, quant: quant)
                            } label: {
                                Text("\(quant.quant) \(String(format: "%.1f", quant.fileSizeGB))GB")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(vm.downloadActivityID != nil)
                            .help(quant.recommended ? "推荐档（\(quant.fileName)）" : quant.fileName)
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }
            // 下载状态读全局活动中心（切页/返回设置页仍可见）
            if let dl = GlobalActivityCenter.shared.items.first(where: { $0.tag == "download" }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("下载：\(dl.title)")
                            .font(.caption)
                        Spacer()
                        if vm.downloadPaused {
                            Button("继续") { vm.resumeDownload() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        } else {
                            Button("暂停") { vm.pauseDownload() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                        Button("取消") { vm.cancelDownload() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    ProgressView(value: dl.progress ?? 0)
                        .progressViewStyle(.linear)
                    HStack(spacing: 8) {
                        if let msg = dl.message {
                            Text(msg).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let bytes = dl.bytes {
                            Text("\(ByteCountFormatter.string(fromByteCount: bytes.received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: bytes.total, countStyle: .file))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 复习调度

    private var schedulingSection: some View {
        section("复习调度") {
            HStack(spacing: 12) {
                Picker("调度算法", selection: Binding(
                    get: { vm.settings.schedulerID },
                    set: { vm.settings.schedulerID = $0 }
                )) {
                    ForEach(SchedulerID.allCases, id: \.rawValue) { sid in
                        Text(label(for: sid)).tag(sid)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                if vm.settings.schedulerID == .fsrsV4 {
                    Text("FSRS 接入中，当前仍用 SM-2")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private func label(for sid: SchedulerID) -> String {
        switch sid {
        case .sm2: return "SM-2（当前）"
        case .fsrsV4: return "FSRS v4（开发中）"
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let msg = vm.statusMessage {
                Text(msg).font(.caption).foregroundStyle(.green)
            }
            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
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
