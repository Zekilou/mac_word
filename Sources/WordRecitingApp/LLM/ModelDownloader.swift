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
    /// 保护 delegate 回调与调用方（async 侧）之间的共享状态。
    /// @ai: `@unchecked Sendable` 意味着需要自己保证线程安全。URLSession 的 delegate 回调
    ///      在 delegateQueue（非主线程）执行，而 pause()/cancel() 由调用方线程触发；
    ///      旧实现对这些 var 完全没有同步 → `continuation` 的「读-置nil-resume」不是原子的，
    ///      与 `didCompleteWithError` 的 `guard continuation != nil` 竞争，
    ///      可能**双重 resume 同一个 CheckedContinuation**（运行时 trap）或丢失 resume 永久挂起。
    private let lock = NSLock()
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var progressHandler: (@Sendable (Int64, Int64) -> Void)?
    private var destination: URL?
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumeData: Data?

    /// 原子取出并清空 continuation（保证只有一个回调能 resume）。
    private func takeContinuation() -> CheckedContinuation<URL, Error>? {
        lock.lock(); defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }

    /// 首次下载到 destination，返回最终文件 URL。
    func download(
        url: URL, to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let task = prepareDownload(destination: destination, progress: progress,
                                   resumeData: nil, url: url)
        return try await awaitCompletion { task.resume() }
    }

    /// 用已保存的 resumeData 从断点继续下载。
    func resume(
        url: URL, to destination: URL, resumeData: Data,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let task = prepareDownload(destination: destination, progress: progress,
                                   resumeData: resumeData, url: url)
        return try await awaitCompletion { task.resume() }
    }

    /// 同步准备阶段（建 session/task 并登记状态）；锁只在同步上下文使用。
    /// @ai: Swift 6 禁止在 async 上下文直接 NSLock.lock/unlock，故把加锁逻辑抽到同步方法。
    private func prepareDownload(
        destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        resumeData: Data?,
        url: URL
    ) -> URLSessionDownloadTask {
        let session = makeSession()
        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: url)
        lock.lock()
        self.destination = destination
        self.progressHandler = progress
        self.resumeData = resumeData
        self.session = session
        self.downloadTask = task
        lock.unlock()
        return task
    }

    /// 暂停：保存续传点（供 resume 使用），当前 await 抛 CancellationError 结束。
    /// - Parameter completion: 拿到 resumeData 后的回调（任意线程）。
    func pause(completion: (@Sendable (Data?) -> Void)? = nil) {
        lock.lock()
        let task = downloadTask
        lock.unlock()
        task?.cancel { [weak self] data in
            guard let self else { completion?(data); return }
            self.lock.lock()
            self.resumeData = data
            self.lock.unlock()
            completion?(data)
        }
        // 原子取出，保证与 delegate 回调不会双重 resume
        takeContinuation()?.resume(throwing: CancellationError())
    }

    /// 取消（不保留续传点）。
    func cancel() {
        lock.lock()
        let task = downloadTask
        lock.unlock()
        task?.cancel()
        takeContinuation()?.resume(throwing: CancellationError())
    }

    // MARK: - 私有

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1800  // 大模型文件，允许长时间无响应
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func awaitCompletion(_ start: () -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            start()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let dest = destination
        lock.unlock()
        guard let dest else { return }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            takeContinuation()?.resume(returning: dest)
        } catch {
            takeContinuation()?.resume(throwing: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        // 主动暂停/取消：continuation 已被取走 → takeContinuation 返回 nil，安全忽略
        guard let cont = takeContinuation() else { return }
        // HTTP 错误（如 404 文件名不对）给出可读状态码
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            cont.resume(throwing: ModelDownloadError.httpStatus(http.statusCode))
        } else {
            cont.resume(throwing: error)
        }
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
