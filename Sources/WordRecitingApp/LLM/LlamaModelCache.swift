import Foundation
import LlamaSwift

/// 进程内模型缓存：模型常驻内存，避免每次生成反复加载/释放 GGUF。
/// @ai: backend 全局初始化一次；同一 modelPath 复用已加载模型（llama 权重只读，
///      可被多个 context 共享，单任务各自建 ctx）；切换模型路径时释放旧模型；
///      空闲超时（默认 5 分钟）后下次访问前惰性释放，腾出内存。
/// 线程安全（NSLock）；推理仍由调用方在 Task.detached 中执行。
final class LlamaModelCache: @unchecked Sendable {
    static let shared = LlamaModelCache()

    private let lock = NSLock()
    private var backendInitialized = false
    private var cachedModel: OpaquePointer?
    private var cachedVocab: OpaquePointer?
    private var cachedPath: String?
    private var lastUsed = Date.distantPast
    /// 模型加载次数（测试观察：同路径命中缓存不递增）。
    private(set) var loadCount = 0

    /// 空闲释放阈值（秒）：超过后下次访问前惰性释放。
    var idleTimeout: TimeInterval = 300

    init() {}

    /// 获取（或加载）指定路径模型的会话；同一路径返回缓存实例。
    /// 切换路径 / 空闲超时都会先释放旧模型再加载。
    func session(for path: String) throws -> (model: OpaquePointer, vocab: OpaquePointer) {
        lock.lock()
        defer { lock.unlock() }
        ensureBackend()
        // 空闲超时：模型长时间未用 → 释放，下次访问重新加载
        if Date().timeIntervalSince(lastUsed) > idleTimeout {
            releaseLocked()
        }
        if let m = cachedModel, cachedPath == path {
            lastUsed = Date()
            return (m, cachedVocab!)
        }
        // 换模型路径：释放旧模型（内存规划：同一时刻只驻留一个模型）
        if cachedModel != nil {
            releaseLocked()
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
        return (m, v)
    }

    /// 主动释放当前模型（用户清空进程内模型 / 应用退出时调用）。
    func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        releaseLocked()
    }

    private func ensureBackend() {
        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }
    }

    private func releaseLocked() {
        if let m = cachedModel { llama_model_free(m) }
        cachedModel = nil
        cachedVocab = nil
        cachedPath = nil
        lastUsed = .distantPast
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
