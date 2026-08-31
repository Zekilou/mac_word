import Foundation

/// 模型下载任务状态（UI 展示用）。
struct ModelDownloadState: Identifiable, Equatable, Sendable {
    var id: String { "\(modelID)-\(quant)" }
    let modelID: String
    let quant: String
    let displayName: String
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// 进度 0~1（总字节未知时返回 0）。
    var progress: Double {
        totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
    }
    var isFinished: Bool { totalBytes > 0 && receivedBytes >= totalBytes }
}

/// 带进度的模型下载器：URLSessionDownloadDelegate 桥接 async/await。
/// 支持**断点续传**：pause() 保存 resumeData（可持久化为缓存），resume() 从断点继续。
/// 下载到系统临时文件 → 完成后移动至目标路径；进度通过 @Sendable 回调上报。
/// @ai: 非 UI 类；进度回调由调用方自行切主线程。取消/暂停调用对应方法。
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var progressHandler: (@Sendable (Int64, Int64) -> Void)?
    private var destination: URL?
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumeData: Data?

    /// 首次下载到 destination，返回最终文件 URL。
    func download(
        url: URL, to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        self.destination = destination
        self.progressHandler = progress
        let session = makeSession()
        self.session = session
        let task = session.downloadTask(with: url)
        self.downloadTask = task
        return try await awaitCompletion { task.resume() }
    }

    /// 用已保存的 resumeData 从断点继续下载。
    func resume(
        url: URL, to destination: URL, resumeData: Data,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        self.destination = destination
        self.progressHandler = progress
        self.resumeData = resumeData
        let session = makeSession()
        self.session = session
        let task = session.downloadTask(withResumeData: resumeData)
        self.downloadTask = task
        return try await awaitCompletion { task.resume() }
    }

    /// 暂停：保存续传点（供 resume 使用），当前 await 抛 CancellationError 结束。
    /// - Parameter completion: 拿到 resumeData 后的回调（任意线程）。
    func pause(completion: (@Sendable (Data?) -> Void)? = nil) {
        downloadTask?.cancel { [weak self] data in
            self?.resumeData = data
            completion?(data)
        }
        let cont = continuation
        continuation = nil
        cont?.resume(throwing: CancellationError())
    }

    /// 取消（不保留续传点）。
    func cancel() {
        downloadTask?.cancel()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    // MARK: - 私有

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1800  // 大模型文件，允许长时间无响应
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func awaitCompletion(_ start: () -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            start()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let dest = destination else { return }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        // 主动暂停/取消：continuation 已被 resume，忽略后续回调
        guard continuation != nil else { return }
        // HTTP 错误（如 404 文件名不对）给出可读状态码
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: ModelDownloadError.httpStatus(http.statusCode))
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}

/// 模型下载错误。
enum ModelDownloadError: LocalizedError, Sendable {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "下载失败（HTTP \(code)）。可能是文件名变更，请刷新模型目录或改用 Ollama 提取。"
        }
    }
}
