import Foundation

/// llama-server 进程管理：spawn 二进制监听 localhost 随机端口供 sidecar 调用。
/// @ai: @MainActor @Observable（UI 绑定 isRunning/port/error）；spawn 后读 stdout 解析端口，
///      轮询 /health 确认就绪；stop 终止进程并清理；单例 .shared 跨视图共享状态。
@MainActor
@Observable
final class LlamaServerProcess {

    static let shared = LlamaServerProcess()

    /// 进程状态。
    enum Status: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private var process: Process?
    private var readerTask: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var lastActivity: Date = .now

    /// 当前状态便捷判断。
    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// sidecar 用的 baseURL（http://127.0.0.1:{port}/v1），未运行返回 nil。
    var baseURL: String? {
        if case .running(let port) = status {
            return "http://127.0.0.1:\(port)/v1"
        }
        return nil
    }

    private init() {}

    // MARK: - 启动 / 停止

    /// spawn llama-server 并等待端口就绪。
    /// - Parameters:
    ///   - binary: llama-server 可执行文件路径。
    ///   - modelPath: GGUF 模型文件路径。
    ///   - contextWindow: 上下文窗口（-c 参数，默认 2048）。
    ///   - startupTimeout: 端口解析 + 健康检查总超时（秒）。
    func spawn(
        binary: URL, modelPath: String,
        contextWindow: Int = 2048,
        startupTimeout: TimeInterval = 60
    ) async throws {
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw LlamaServerError.binaryNotFound
        }

        status = .starting
        let p = Process()
        p.executableURL = binary
        // --port 0 让系统分配端口；--host 127.0.0.1 仅本地；-ngl 99 Metal 全卸载
        p.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", "0",
            "-c", String(contextWindow),
            "-ngl", "99",
        ]
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = stdout  // 合并 stderr 到 stdout（llama-server 端口信息可能在 stderr）
        p.standardInput = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
        process = p

        // 读 stdout 解析端口（带超时）
        do {
            let port = try await waitForPort(
                pipe: stdout, timeout: startupTimeout)
            try await waitForHealth(port: port, timeout: max(5, startupTimeout - 30))
            status = .running(port: port)
            touchActivity()
        } catch {
            stopInternal()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 停止进程并清理状态。
    func stop() {
        stopInternal()
        status = .stopped
    }

    /// 标记活动（用于 idleTimeout 生命周期，生成前后调用）。
    func touchActivity() {
        lastActivity = .now
    }

    /// 启动闲置超时停（仅 .idleTimeout 生命周期调用）。
    /// 每 30s 检查一次，超过 idleSeconds 无活动则 stop。
    func startIdleWatcher(idleSeconds: TimeInterval = LlamaServerLifecycle.idleTimeoutSeconds) {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self, self.isRunning else { return }
                await MainActor.run {
                    if Date.now.timeIntervalSince(self.lastActivity) >= idleSeconds {
                        self.stop()
                    }
                }
            }
        }
    }

    func stopIdleWatcher() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    // MARK: - 内部

    private func stopInternal() {
        readerTask?.cancel()
        readerTask = nil
        process?.terminate()
        process = nil
    }

    /// 读 stdout 逐行解析端口（llama-server 输出 "listening on http://127.0.0.1:PORT"）。
    private func waitForPort(pipe: Pipe, timeout: TimeInterval) async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let box = PortContinuationBox(cont: cont)
            readerTask = Task { [weak self] in
                do {
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        if let port = Self.parsePort(from: line) {
                            box.resume(port)
                            return
                        }
                        if Task.isCancelled { break }
                    }
                    // EOF：进程退出未找到端口
                    box.fail(LlamaServerError.binaryNotFound)
                    await MainActor.run { self?.status = .failed("llama-server 提前退出") }
                } catch {
                    box.fail(error)
                }
            }
            // 超时兜底
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !box.isDone {
                    box.fail(LlamaServerError.extractFailed("启动超时（未找到端口）"))
                    await MainActor.run { self?.stopInternal() }
                }
            }
        }
    }

    /// 轮询 GET /health 直到 200 或超时。
    private func waitForHealth(port: Int, timeout: TimeInterval) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            throw LlamaServerError.invalidURL
        }
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    return
                }
            } catch {
                // 端口未就绪，继续重试
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LlamaServerError.extractFailed("健康检查超时")
    }

    /// 从一行输出解析端口号（匹配 "listening on http://host:PORT" 或 "port PORT"）。
    /// @ai: nonisolated 纯函数（无 actor 状态访问），供测试直接调用。
    nonisolated static func parsePort(from line: String) -> Int? {
        // 常见格式：llama-server: listening on http://127.0.0.1:8080
        // 也匹配：server: port = 8080 / listening on *:8080
        if let range = line.range(of: #"(?:listening on \S*?:|port\s*=?\s*)(\d{2,5})"#,
                                  options: .regularExpression) {
            let nsRange = NSRange(range, in: line)
            if let portRange = Range(nsRange, in: line),
               let matchRange = line[portRange].range(of: #"\d{2,5}$"#, options: .regularExpression),
               let port = Int(line[portRange][matchRange]) {
                return port
            }
        }
        // 兜底：行末独立 4-5 位数字 + 行含 "listen"/"port"
        let lower = line.lowercased()
        if lower.contains("listen") || lower.contains("port") {
            if let match = line.range(of: #"\b(\d{4,5})\b"#, options: .regularExpression),
               let port = Int(line[match]) {
                return port
            }
        }
        return nil
    }
}

/// continuation 一次性安全包装（防多次 resume）。
private final class PortContinuationBox: @unchecked Sendable {
    private let cont: CheckedContinuation<Int, Error>
    private var done = false
    private let lock = NSLock()

    init(cont: CheckedContinuation<Int, Error>) { self.cont = cont }

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    func resume(_ port: Int) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(returning: port)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(throwing: error)
    }
}
