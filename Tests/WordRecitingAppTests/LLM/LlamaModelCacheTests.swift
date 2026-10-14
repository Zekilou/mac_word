import XCTest
import LlamaSwift
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

        var firstPtr: OpaquePointer?
        var secondPtr: OpaquePointer?
        try cache.withSession(for: path) { m, _ in firstPtr = m }
        try cache.withSession(for: path) { m, _ in secondPtr = m }
        XCTAssertEqual(cache.loadCount, 1, "同路径应命中缓存，不重复加载")
        XCTAssertTrue(firstPtr == secondPtr, "应复用同一模型指针")
    }

    func testCacheReloadsAfterIdleTimeout() throws {
        let path = try firstModel()
        let cache = LlamaModelCache()
        cache.idleTimeout = 0   // 每次访问都视为空闲超时
        defer { cache.releaseAll() }

        try cache.withSession(for: path) { _, _ in }
        try cache.withSession(for: path) { _, _ in }
        XCTAssertEqual(cache.loadCount, 2, "空闲超时后应重新加载")
    }

    func testCacheSwitchesPathReleasesOldModel() throws {
        let path = try firstModel()
        let cache = LlamaModelCache()
        defer { cache.releaseAll() }

        try cache.withSession(for: path) { _, _ in }
        // 加载不存在路径 → 抛错
        XCTAssertThrowsError(try cache.withSession(for: "/nonexistent/model.gguf") { _, _ in })
        // 旧模型已被换下并释放（无在飞租约）→ 再加载同路径需重新加载
        try cache.withSession(for: path) { _, _ in }
        XCTAssertEqual(cache.loadCount, 2, "切换路径后旧模型已释放，应重新加载")
    }

    // MARK: - 租约生命周期（回归：use-after-free）

    /// 回归：租约进行中不得释放模型。
    /// @ai: 旧实现把裸指针交给调用方后，另一线程 releaseAll()（应用退出）
    ///      或 session(for: 别的路径)（切模型）会立刻 llama_model_free，
    ///      正在解码的权重被释放 → use-after-free。现在释放必须挂起到租约归还。
    func testReleaseAllIsDeferredWhileLeaseIsActive() throws {
        let path = try firstModel()
        let cache = LlamaModelCache()
        defer { cache.releaseAll() }

        try cache.withSession(for: path) { _, _ in
            XCTAssertEqual(cache.activeLeaseCount, 1, "闭包内应持有租约")
            // 模拟并发触发的「退出释放」——必须被挂起，不能 free 掉正在用的模型
            cache.releaseAll()
            XCTAssertTrue(cache.hasCachedModel, "有在飞租约时不得释放模型")
        }
        // 租约归还后才允许真正释放
        XCTAssertEqual(cache.activeLeaseCount, 0)
        XCTAssertFalse(cache.hasCachedModel, "租约结束后挂起的释放应执行")
    }

    /// 回归：租约进行中切换模型路径，旧模型须等租约结束才释放（不能泄漏也不能提前 free）。
    func testPathSwitchRetiresOldModelUntilLeaseEnds() throws {
        let path = try firstModel()
        let cache = LlamaModelCache()
        defer { cache.releaseAll() }

        try cache.withSession(for: path) { _, _ in
            // 租约内切换到另一个（不存在的）路径：加载失败，但旧模型已被换下
            _ = try? cache.withSession(for: "/nonexistent/model.gguf") { _, _ in }
            XCTAssertGreaterThanOrEqual(cache.retiredModelCount, 1,
                           "旧模型应进入 retired 队列等待租约结束（不可提前 free，也不可泄漏）")
        }
        XCTAssertEqual(cache.retiredModelCount, 0, "租约结束后 retired 模型应被释放")
    }

    /// 租约计数必须严格配对（异常路径也不能泄漏租约）。
    func testLeaseIsReleasedWhenBodyThrows() throws {
        let path = try firstModel()
        let cache = LlamaModelCache()
        defer { cache.releaseAll() }

        struct Boom: Error {}
        XCTAssertThrowsError(try cache.withSession(for: path) { _, _ in throw Boom() })
        XCTAssertEqual(cache.activeLeaseCount, 0, "抛错后租约必须归还")
        // 归还后可以正常释放
        cache.releaseAll()
        XCTAssertFalse(cache.hasCachedModel)
    }
}
