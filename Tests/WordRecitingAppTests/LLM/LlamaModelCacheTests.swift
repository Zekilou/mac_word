import XCTest
@testable import WordRecitingApp

/// LlamaModelCache 测试：模型常驻复用（避免每次生成反复加载 GGUF）。
/// 需要模型目录存在 .gguf；无模型则跳过（不视为失败）。
final class LlamaModelCacheTests: XCTestCase {

    private func firstModel() throws -> String {
        let store = ModelStore()
        let models = store.discoveredModels()
        guard !models.isEmpty else { throw XCTSkip("模型目录无 GGUF 文件") }
        return models[0].url.path
    }

    func testCacheReusesModelForSamePath() throws {
        let path = try firstModel()
        let cache = LlamaModelCache()
        defer { cache.releaseAll() }

        let s1 = try cache.session(for: path)
        let s2 = try cache.session(for: path)
        XCTAssertEqual(cache.loadCount, 1, "同路径应命中缓存，不重复加载")
        XCTAssertTrue(s1.model == s2.model, "应复用同一模型指针")
    }

    func testCacheReloadsAfterIdleTimeout() throws {
        let path = try firstModel()
        let cache = LlamaModelCache()
        cache.idleTimeout = 0   // 每次访问都视为空闲超时
        defer { cache.releaseAll() }

        _ = try cache.session(for: path)
        _ = try cache.session(for: path)
        XCTAssertEqual(cache.loadCount, 2, "空闲超时后应重新加载")
    }

    func testCacheSwitchesPathReleasesOldModel() throws {
        let path = try firstModel()
        let cache = LlamaModelCache()
        defer { cache.releaseAll() }

        _ = try cache.session(for: path)
        // 加载不存在路径 → 抛错，且旧模型已释放
        XCTAssertThrowsError(try cache.session(for: "/nonexistent/model.gguf"))
        // 旧模型已释放 → 再加载同路径需重新加载
        _ = try cache.session(for: path)
        XCTAssertEqual(cache.loadCount, 2, "切换路径后旧模型已释放，应重新加载")
    }
}
