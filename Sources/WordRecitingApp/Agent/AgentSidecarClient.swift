import Foundation

/// Agent sidecar 客户端：spawn sidecar.py / 打包后的单文件，经 stdio JSONL 通信。
/// @ai: 非隔离（@unchecked Sendable）——供 ContentGenerator 协议（非 @MainActor）直接调用；
///      内部用 NSLock 保护 pending/streams 注册表；stdout 走 AsyncBytes 流式。
///      生命周期：start/ping/stop + generate 流式事件（Task 2/6 契约）。
final class AgentSidecarClient: @unchecked Sendable {

    private let process: Process
    private let stdout = Pipe()
    private let stdin = Pipe()
    private let lock = NSLock()
    private var readerTask: Task<Void, Never>?
    /// 单次请求（ping）的挂起 continuation。
    private var pending: [Int: CheckedContinuation<AgentSidecarProtocol.Event, Error>] = [:]
    /// 流式请求（generate）的挂起 continuation（Event 逐条 yield，result/error 收尾）。
    private var streams: [Int: AsyncThrowingStream<AgentSidecarProtocol.Event, Error>.Continuation] = [:]
    private var nextID = 1
    private(set) var isRunning = false

    /// - Parameters:
    ///   - executable: sidecar 可执行（开发期 venv python；打包后单文件 agents-sidecar）
    ///   - scriptPath: sidecar.py 路径（单文件模式传 nil）
    init(executable: URL, scriptPath: URL?) {
        process = Process()
        process.executableURL = executable
        if let scriptPath {
            process.arguments = [scriptPath.path]
        }
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
    }

    /// 启动子进程并开始读取 stdout 事件行。
    func start() throws {
        guard !isRunning else { return }
        try process.run()
        isRunning = true
        readerTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in self.stdout.fileHandleForReading.bytes.lines {
                    self.handle(line: line)
                }
                // EOF：进程退出/崩溃 → 失败全部挂起（防 generate 流永久悬挂）
                self.failAll(AgentSidecarError.clientStopped)
            } catch {
                self.failAll(error)
            }
        }
    }

    /// 握手：发送 ping，等待 pong（或 error/超时）。
    func ping(timeout: TimeInterval = 3.0) async throws -> Bool {
        try start()
        let id = nextRequestID()
        let event = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AgentSidecarProtocol.Event, Error>) in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            let line = AgentSidecarProtocol.request(id: id, method: "ping") + "\n"
            stdin.fileHandleForWriting.write(Data(line.utf8))
            // 超时兜底（后台 Task 持有 weak self，避免延迟清理已释放对象）
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finishPendingWithTimeout(id: id)
            }
        }
        switch event {
        case .pong: return true
        case .error(_, _, let message):
            throw AgentSidecarError.respondedError(message)
        default:
            return false
        }
    }

    /// 发起 generate 请求，返回流式事件序列。
    /// 事件流以 .result 正常结束，或 .error / 进程终止 / 流取消抛错。
    /// @ai: 调用方必须消费流直到结束（或取消），否则 sidecar 端事件无人读取不阻塞（无背压）。
    func generate(params: [String: Any]) throws -> AsyncThrowingStream<AgentSidecarProtocol.Event, Error> {
        try start()
        let id = nextRequestID()
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: AgentSidecarProtocol.Event.self)
        lock.lock()
        streams[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.removeStream(id: id)
        }
        let line = AgentSidecarProtocol.request(id: id, method: "generate", params: params) + "\n"
        stdin.fileHandleForWriting.write(Data(line.utf8))
        return stream
    }

    /// 终止子进程并清理。
    func stop() {
        readerTask?.cancel()
        readerTask = nil
        if isRunning {
            process.terminate()
        }
        failAll(AgentSidecarError.clientStopped)
    }

    // MARK: - 内部

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func handle(line: String) {
        guard let event = AgentSidecarProtocol.Event.parse(line) else { return }
        switch event {
        case .pong(let pid):
            lock.lock()
            let cont = pending.removeValue(forKey: pid)
            lock.unlock()
            cont?.resume(returning: event)
        case .result(let rid, _, _):
            lock.lock()
            if let s = streams.removeValue(forKey: rid) {
                lock.unlock()
                s.yield(event)
                s.finish()
            } else {
                let cont = pending.removeValue(forKey: rid)
                lock.unlock()
                cont?.resume(returning: event)
            }
        case .error(let eid, _, let message):
            if let eid {
                lock.lock()
                if let s = streams.removeValue(forKey: eid) {
                    lock.unlock()
                    s.finish(throwing: AgentSidecarError.respondedError(message))
                    return
                }
                let cont = pending.removeValue(forKey: eid)
                lock.unlock()
                cont?.resume(returning: event)
            }
            // 无 id 的错误（bad_request 等）无挂起可关联，忽略
        case .stage(let rid, _), .thought(let rid, _), .token(let rid, _):
            lock.lock()
            let s = streams[rid]
            lock.unlock()
            s?.yield(event)
        }
    }

    private func removeStream(id: Int) {
        lock.lock()
        streams.removeValue(forKey: id)
        lock.unlock()
    }

    private func finishPendingWithTimeout(id: Int) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(throwing: AgentSidecarError.timeout)
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let allPending = pending
        pending.removeAll()
        let allStreams = streams
        streams.removeAll()
        isRunning = false
        lock.unlock()
        for (_, cont) in allPending {
            cont.resume(throwing: error)
        }
        for (_, s) in allStreams {
            s.finish(throwing: error)
        }
    }
}

enum AgentSidecarError: LocalizedError {
    case respondedError(String)
    case clientStopped
    case timeout

    var errorDescription: String? {
        switch self {
        case .respondedError(let m): return "sidecar 错误：\(m)"
        case .clientStopped: return "sidecar 已停止"
        case .timeout: return "sidecar 无响应"
        }
    }
}
