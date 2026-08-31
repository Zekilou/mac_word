import Foundation
import Observation

/// SettingsViewModel 本地 agent 增强扩展：llama-server 下载 + 进程生命周期管理。
/// @ai: 拆分到扩展文件控制主文件行数；逻辑与模型下载平级，复用 GlobalActivityCenter 托管。
extension SettingsViewModel {

    /// llama-server 二进制是否就绪（已下载且可执行）。
    var llamaServerBinaryReady: Bool {
        LlamaServerDownloader().existingBinary() != nil
    }

    /// llama-server 进程当前状态（UI 绑定 LlamaServerProcess.shared.status）。
    var llamaServerStatus: LlamaServerProcess.Status {
        LlamaServerProcess.shared.status
    }

    /// llama-server 是否运行中（UI 便捷判断，避免枚举关联值 == 比较）。
    var llamaServerIsRunning: Bool {
        LlamaServerProcess.shared.isRunning
    }

    /// 是否正在下载 llama-server（查全局中心 tag）。
    var llamaServerDownloading: Bool {
        GlobalActivityCenter.shared.items.contains { $0.tag == "llama-server-download" }
    }

    // MARK: - 下载 llama-server

    /// 下载最新 llama-server 二进制（托管到全局活动中心，切页不中断）。
    /// @ai: 默认用 fallbackTag（不查 GitHub API，避免国内卡死）；tag 传 nil 用 fallback。
    func downloadLlamaServer() {
        guard !llamaServerDownloading else { return }
        errorMessage = nil
        let activityID = GlobalActivityCenter.shared.begin(
            title: "下载 llama-server（本地 agent 增强）", icon: "arrow.down.circle",
            tag: "llama-server-download", progress: 0.0,
            message: "准备下载 b\(LlamaServerRelease.fallbackTag.dropFirst())…")
        let downloader = LlamaServerDownloader()
        let progress: @Sendable (Int64, Int64) -> Void = { received, total in
            Task { @MainActor in
                GlobalActivityCenter.shared.update(
                    activityID,
                    progress: total > 0 ? Double(received) / Double(total) : 0.0,
                    message: total > 0 ? "下载中…" : "连接中…",
                    bytes: .init(received: received, total: total))
            }
        }
        GlobalActivityCenter.shared.run(activityID, onCancel: nil) {
            do {
                let url = try await downloader.download(tag: nil, progress: progress)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.settings.llamaServerBinaryPath = url.path
                    GlobalActivityCenter.shared.end(activityID)
                    self.statusMessage = "llama-server 已就绪：\(url.lastPathComponent)"
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    GlobalActivityCenter.shared.end(activityID)
                    self.errorMessage = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 检查最新版本（手动触发，走 GitHub API，5s 超时后弹错误）。
    /// @ai: 用户主动检查更新用；下载默认走 fallbackTag 不需要此步。
    func checkLatestLlamaServer() async {
        let tag = await LlamaServerRelease.latestTag()
        if tag == LlamaServerRelease.fallbackTag {
            errorMessage = "GitHub API 不可达，使用内置版本 \(LlamaServerRelease.fallbackTag)"
        } else {
            statusMessage = "最新版本：\(tag)（内置 \(LlamaServerRelease.fallbackTag)，下载时如需更新请手动指定）"
        }
    }

    // MARK: - 进程生命周期

    /// 启动 llama-server（按当前生命周期策略 + 已选模型路径）。
    /// @ai: persistent/idleTimeout 在此启动常驻；perGenerate 由生成流程按需调用。
    func startLlamaServer() async {
        guard llamaServerBinaryReady,
              let modelPath = settings.localModelPath, !modelPath.isEmpty,
              let binary = LlamaServerDownloader().existingBinary() else {
            errorMessage = "请先下载 llama-server 并选择进程内 GGUF 模型"
            return
        }
        do {
            try await LlamaServerProcess.shared.spawn(
                binary: binary, modelPath: modelPath,
                contextWindow: settings.contextWindow)
            // idleTimeout 启动闲置监控
            if settings.llamaServerLifecycle == .idleTimeout {
                LlamaServerProcess.shared.startIdleWatcher()
            }
        } catch {
            errorMessage = "启动 llama-server 失败：\(error.localizedDescription)"
        }
    }

    /// 停止 llama-server。
    func stopLlamaServer() {
        LlamaServerProcess.shared.stopIdleWatcher()
        LlamaServerProcess.shared.stop()
    }

    /// 应用生命周期变更：切换策略时调整运行状态。
    /// @ai: persistent → 保持运行；perGenerate → 停止常驻（生成时按需启）；idleTimeout → 重启 watcher。
    func applyLifecycleChange() async {
        let lifecycle = settings.llamaServerLifecycle
        switch lifecycle {
        case .persistent:
            // 确保运行
            if !LlamaServerProcess.shared.isRunning {
                await startLlamaServer()
            }
            LlamaServerProcess.shared.stopIdleWatcher()
        case .perGenerate:
            // 停止常驻，生成时按需启
            stopLlamaServer()
        case .idleTimeout:
            // 保持运行 + 启动 watcher
            if !LlamaServerProcess.shared.isRunning {
                await startLlamaServer()
            } else {
                LlamaServerProcess.shared.startIdleWatcher()
            }
        }
    }
}
