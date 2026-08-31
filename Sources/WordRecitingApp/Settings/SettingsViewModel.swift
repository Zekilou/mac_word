import Foundation
import Observation

/// 设置 ViewModel：LLM 生成配置（持久化）+ 进程内模型管理 + 复习调度。
/// @ai: 设置写 AppSettings（UserDefaults）；模型文件操作走 ModelStore。
@MainActor
@Observable
final class SettingsViewModel {

    let settings: AppSettings
    let store: ModelStore

    // 进程内模型
    var localModels: [LocalModel] = []
    var ollamaCandidates: [OllamaModelCandidate] = []
    var errorMessage: String?
    var statusMessage: String?

    // MARK: - 一键下载（支持缓存续传 + 暂停/恢复）

    /// 当前下载在全局活动中心的注册 id（设置页定位/取消用）。
    private(set) var downloadActivityID: UUID?
    /// 是否已暂停（UI 显示"继续"）。
    private(set) var downloadPaused = false
    /// 下载器持有（暂停/取消用）。
    private var downloader: ModelDownloader?
    /// 断点续传数据（暂停时保存；恢复时使用）。
    private var resumeData: Data?
    /// 续传缓存文件（持久化到模型目录，重启后可继续）。
    private var resumeDataURL: URL?
    /// 当前下载的文件信息（恢复时重建 URL 用）。
    private var downloadFile: (modelID: String, fileName: String)?

    init(settings: AppSettings = .shared, store: ModelStore = ModelStore()) {
        self.settings = settings
        self.store = store
    }

    // MARK: - 远端配置（切服务类型时重置默认值）

    func switchRemoteProvider(_ provider: RemoteProvider) {
        settings.remoteProvider = provider
        settings.applyProviderDefaults()
    }

    // MARK: - 联通性 + 模型类型探测（配置变更时触发）

    /// 对当前生效的 API 配置发起联通性 + 思考型探测，结果写回 APIConfig.isThinking。
    /// @ai: 探测是异步网络请求，不阻塞 UI；失败保留原判定不打断。
    func probeActiveConfig() {
        let config = settings.activeAPIConfig
        let client = OpenAICompatibleClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey.isEmpty ? nil : config.apiKey,
            model: config.model)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await client.probe()
            guard result.reachable else { return }
            var updated = self.settings.activeAPIConfig
            updated.isThinking = result.isThinking
            self.settings.upsertAPIConfig(updated)
        }
    }

    // MARK: - 进程内模型

    /// 刷新本地模型列表与 Ollama 候选。
    func reload() {
        localModels = store.discoveredModels()
        ollamaCandidates = ModelStore.ollamaCandidates()
        errorMessage = nil
    }

    /// 选择当前使用的模型文件。
    func selectModel(_ model: LocalModel) {
        settings.localModelPath = model.url.path
        statusMessage = "已选择：\(model.fileName)"
    }

    /// 导入用户选择的 .gguf 文件到模型目录并选中。
    func importModel(from url: URL) {
        do {
            let dest = try store.importModel(from: url)
            settings.localModelPath = dest.path
            reload()
            statusMessage = "已导入：\(dest.lastPathComponent)"
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 从 Ollama 提取模型为 GGUF 并选中。
    func extractOllama(_ candidate: OllamaModelCandidate) {
        do {
            let dest = try store.extractOllamaModel(candidate)
            settings.localModelPath = dest.path
            reload()
            statusMessage = "已提取：\(dest.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 一键下载

    /// 从 hf-mirror 下载模型（带进度、可暂停续传）。下载任务托管到全局活动中心，
    /// 切换页面/销毁 View 不会中断；若存在续传缓存则直接续传（断点续传）。
    func downloadModel(_ entry: ModelEntry, quant: QuantOption) {
        guard downloadActivityID == nil else { return }
        errorMessage = nil
        statusMessage = nil
        downloadFile = (entry.modelID, quant.fileName)
        let cacheURL = resumeCacheURL(fileName: quant.fileName)
        resumeDataURL = cacheURL
        // 缓存续传点：优先断点续传
        if let cached = try? Data(contentsOf: cacheURL), !cached.isEmpty {
            resumeData = cached
            startDownload(resumeData: cached)
        } else {
            resumeData = nil
            startDownload(resumeData: nil)
        }
    }

    /// 启动下载（首次或续传）：任务托管到全局中心。
    private func startDownload(resumeData: Data?) {
        guard let (modelID, fileName) = downloadFile else { return }
        let activityID = GlobalActivityCenter.shared.begin(
            title: "下载模型（\(fileName)）", icon: "arrow.down.circle",
            tag: "download", progress: resumeData == nil ? 0.0 : nil,
            message: resumeData == nil ? "连接中…" : "断点续传中…")
        downloadActivityID = activityID
        downloadPaused = false
        guard let url = URL(string: HFMirror.resolve(modelID: modelID, filename: fileName)) else {
            GlobalActivityCenter.shared.end(activityID)
            downloadActivityID = nil
            errorMessage = "下载地址无效"
            return
        }
        let dest = store.modelsDirectory.appendingPathComponent(fileName)
        let downloader = ModelDownloader()
        self.downloader = downloader
        let progress = downloadProgress(activityID)
        GlobalActivityCenter.shared.run(activityID, onCancel: {
            downloader.cancel()
        }) {
            do {
                let result: URL
                if let data = resumeData {
                    result = try await downloader.resume(
                        url: url, to: dest, resumeData: data, progress: progress)
                } else {
                    result = try await downloader.download(
                        url: url, to: dest, progress: progress)
                }
                await MainActor.run { [weak self] in
                    self?.finishDownload(url: result, fileName: fileName, keepCache: false)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.downloader = nil
                    if !self.downloadPaused {
                        // 主动取消：清缓存并收尾
                        self.deleteResumeCache(fileName: fileName)
                        self.downloadActivityID = nil
                        self.statusMessage = "下载已取消"
                    }
                    // 暂停时不收尾（暂停项由 pauseDownload 重新注册）
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.deleteResumeCache(fileName: fileName)
                    self.downloader = nil
                    self.downloadActivityID = nil
                    self.errorMessage = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 暂停下载：保存续传点（持久化为缓存），当前任务结束。
    func pauseDownload() {
        guard !downloadPaused, let id = downloadActivityID else { return }
        downloadPaused = true
        let progress = GlobalActivityCenter.shared.items.first { $0.id == id }?.progress
        downloader?.pause { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.resumeData = data
                if let data, let url = self.resumeDataURL {
                    try? data.write(to: url, options: .atomic)  // 缓存续传点
                }
                self.downloader = nil
                GlobalActivityCenter.shared.end(id)
                self.downloadActivityID = GlobalActivityCenter.shared.begin(
                    title: "下载模型（已暂停）", icon: "arrow.down.circle",
                    tag: "download", progress: progress ?? 0, message: "已暂停")
            }
        }
    }

    /// 恢复下载：从断点继续。
    func resumeDownload() {
        guard downloadPaused, let id = downloadActivityID, let data = resumeData else { return }
        GlobalActivityCenter.shared.update(id, message: "继续下载…")
        guard let (modelID, fileName) = downloadFile,
              let url = URL(string: HFMirror.resolve(modelID: modelID, filename: fileName)) else {
            return
        }
        let dest = store.modelsDirectory.appendingPathComponent(fileName)
        let downloader = ModelDownloader()
        self.downloader = downloader
        let progress = downloadProgress(id)
        GlobalActivityCenter.shared.run(id, onCancel: {
            downloader.cancel()
        }) {
            do {
                let result = try await downloader.resume(
                    url: url, to: dest, resumeData: data, progress: progress)
                await MainActor.run { [weak self] in
                    self?.finishDownload(url: result, fileName: fileName, keepCache: false)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.downloader = nil
                    if !self.downloadPaused {
                        self.deleteResumeCache(fileName: fileName)
                        self.downloadActivityID = nil
                        self.statusMessage = "下载已取消"
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.deleteResumeCache(fileName: fileName)
                    self.downloader = nil
                    self.downloadActivityID = nil
                    self.errorMessage = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 取消当前下载（清缓存 + 全局中心取消）。
    func cancelDownload() {
        guard let id = downloadActivityID, let fileName = downloadFile?.fileName else { return }
        downloadPaused = false
        deleteResumeCache(fileName: fileName)
        resumeData = nil
        downloader = nil
        downloadActivityID = nil
        GlobalActivityCenter.shared.cancel(id)
        statusMessage = "下载已取消"
    }

    // MARK: - 下载私有辅助

    /// 下载完成的收尾：选中 + 刷新 + 清理状态。
    private func finishDownload(url: URL, fileName: String, keepCache: Bool) {
        if !keepCache { deleteResumeCache(fileName: fileName) }
        resumeData = nil
        downloader = nil
        downloadActivityID = nil
        settings.localModelPath = url.path
        reload()
        statusMessage = "已下载并选中：\(url.lastPathComponent)"
    }

    /// 进度回调：更新全局活动中心（进度 + 字节）。
    private func downloadProgress(_ id: UUID) -> @Sendable (Int64, Int64) -> Void {
        { received, total in
            Task { @MainActor in
                GlobalActivityCenter.shared.update(
                    id,
                    progress: total > 0 ? Double(received) / Double(total) : 0.0,
                    bytes: .init(received: received, total: total))
            }
        }
    }

    /// 续传缓存文件路径（模型目录下 .resume-<fileName>.data）。
    private func resumeCacheURL(fileName: String) -> URL {
        store.modelsDirectory.appendingPathComponent(".resume-\(fileName).data")
    }

    private func deleteResumeCache(fileName: String) {
        try? FileManager.default.removeItem(at: resumeCacheURL(fileName: fileName))
    }
}
