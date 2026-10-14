import Foundation
import LlamaSwift

/// 进程内模型缓存：模型常驻内存，避免每次生成反复加载/释放 GGUF。
/// @ai: backend 全局初始化一次；同一 modelPath 复用已加载模型（llama 权重只读，
///      可被多个 context 共享，单任务各自建 ctx）；切换模型路径时释放旧模型；
///      空闲超时（默认 5 分钟）后下次访问前惰性释放，腾出内存。
///
///      **生命周期安全（重要）**：`llama_model_free` 必须在没有任何在飞推理时执行。
///      旧实现把裸指针交给调用方后，另一线程的 `session()`（换模型/空闲超时）或
///      `releaseAll()`（应用退出）会立刻 free 掉正在解码的权重 → use-after-free。
///      现在改为**租约（lease）+ 作用域 API**：
///        - `withSession(for:_:)` 在闭包执行期间持有租约，闭包返回后才可能释放；
///        - 释放请求在仍有租约时挂起（pendingRelease），最后一个租约结束才真正 free；
///      调用方不得把指针带出闭包（编译器无法强制，靠约定 + 唯一调用点约束）。
///      线程安全（NSLock）；推理仍在调用方的 Task.detached 中执行。
final class LlamaModelCache: @unchecked Sendable {
    static let shared = LlamaModelCache()

    private let lock = NSLock()
    private var backendInitialized = false
    private var cachedModel: OpaquePointer?
    private var cachedVocab: OpaquePointer?
    private var cachedPath: String?
    private var lastUsed = Date.distantPast
    /// 当前在飞租约数（>0 时禁止真正释放模型）。
    private var leaseCount = 0
    /// 已换下、但仍有租约在用的旧模型 —— 等租约全部归还后再 free。
    /// @ai: 换模型路径时必须先把旧模型挪到这里，否则要么泄漏、要么 free 掉在飞推理的权重。
    private var retiredModels: [OpaquePointer] = []
    /// 空闲/退出触发的释放请求：有租约时挂起，最后一个租约结束才执行。
    private var pendingRelease = false
    /// 模型加载次数（测试观察：同路径命中缓存不递增）。
    private(set) var loadCount = 0

    /// 空闲释放阈值（秒）：超过后下次访问前惰性释放。
    var idleTimeout: TimeInterval = 300

    init() {}

    /// 在租约保护下使用模型：闭包执行期间模型不会被释放。
    /// - Parameter path: GGUF 模型路径。
    /// - Parameter body: 接收 (model, vocab)；**不得**把指针存到闭包外使用。
    /// @ai: 这是唯一允许触碰模型指针的入口——保证 free 不会与 decode 竞争。
    func withSession<T>(
        for path: String,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        let (model, vocab) = try acquire(for: path)
        defer { releaseLease() }
        return try body(model, vocab)
    }

    /// 获取模型并占用一个租约（调用方**必须**配对 `releaseLease()`）。
    private func acquire(for path: String) throws -> (OpaquePointer, OpaquePointer) {
        lock.lock()
        defer { lock.unlock() }
        ensureBackend()
        // 空闲超时：只有无人使用时才释放
        if leaseCount == 0, Date().timeIntervalSince(lastUsed) > idleTimeout {
            releaseLocked()
        }
        if let m = cachedModel, cachedPath == path {
            lastUsed = Date()
            leaseCount += 1
            return (m, cachedVocab!)
        }
        // 换模型路径：把旧模型挪到 retired（仍有租约时不能 free）
        if let old = cachedModel {
            retiredModels.append(old)
            cachedModel = nil
            cachedVocab = nil
            cachedPath = nil
            lastUsed = .distantPast
        }
        // 无租约在飞 → 可以立刻清掉 retired（含此前挂起的释放请求）
        if leaseCount == 0 {
            freeRetiredLocked()
            pendingRelease = false
        }
        var params = llama_model_default_params()
        params.n_gpu_layers = -1
        guard let m = llama_model_load_from_file(path, params) else {
            throw LlamaModelCacheError.loadFailed(path)
        }
        guard let v = llama_model_get_vocab(m) else {
            llama_model_free(m)
            throw LlamaModelCacheError.loadFailed(path)
        }
        cachedModel = m
        cachedVocab = v
        cachedPath = path
        lastUsed = Date()
        loadCount += 1
        leaseCount += 1
        return (m, v)
    }

    /// 归还一个租约；租约归零时执行挂起的释放与 retired 清理。
    private func releaseLease() {
        lock.lock()
        defer { lock.unlock() }
        leaseCount = max(0, leaseCount - 1)
        lastUsed = Date()
        guard leaseCount == 0 else { return }
        // 最后一个租约结束：清掉换下的旧模型
        freeRetiredLocked()
        if pendingRelease { releaseLocked() }
    }

    /// 主动释放当前模型（用户清空进程内模型 / 应用退出时调用）。
    /// @ai: 若有在飞推理（leaseCount > 0），释放会**挂起**到最后一个租约结束，
    ///      避免 free 掉正在解码的权重（use-after-free）。
    func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        if leaseCount > 0 {
            pendingRelease = true
            return
        }
        freeRetiredLocked()
        releaseLocked()
    }

    /// 当前在飞租约数（测试用）。
    var activeLeaseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return leaseCount
    }

    /// 当前是否真的持有模型（测试用）。
    var hasCachedModel: Bool {
        lock.lock(); defer { lock.unlock() }
        return cachedModel != nil
    }

    /// 已换下、等待释放的模型数（测试用）。
    var retiredModelCount: Int {
        lock.lock(); defer { lock.unlock() }
        return retiredModels.count
    }

    private func ensureBackend() {
        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }
    }

    private func freeRetiredLocked() {
        for m in retiredModels { llama_model_free(m) }
        retiredModels.removeAll()
    }

    private func releaseLocked() {
        if let m = cachedModel { llama_model_free(m) }
        cachedModel = nil
        cachedVocab = nil
        cachedPath = nil
        lastUsed = .distantPast
        pendingRelease = false
    }
}

enum LlamaModelCacheError: LocalizedError, Sendable {
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let path):
            return "无法加载模型文件：\(path)"
        }
    }
}
