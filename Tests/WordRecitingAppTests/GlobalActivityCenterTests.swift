import XCTest
@testable import WordRecitingApp

/// GlobalActivityCenter（进程守护）注册表与托管执行测试。
@MainActor
final class GlobalActivityCenterTests: XCTestCase {

    private var center: GlobalActivityCenter { .shared }

    func testBeginAddsItemWithFields() {
        let id = center.begin(title: "生成文章", icon: "sparkles", progress: 0.3, message: "润色中")
        defer { center.end(id) }
        XCTAssertEqual(center.items.count, 1)
        let item = center.items[0]
        XCTAssertEqual(item.title, "生成文章")
        XCTAssertEqual(item.icon, "sparkles")
        XCTAssertEqual(item.progress, 0.3)
        XCTAssertEqual(item.message, "润色中")
    }

    // MARK: - startedAt（详细面板运行时长字段）

    func testBeginFillsStartedAtCloseToNow() {
        let before = Date()
        let id = center.begin(title: "T")
        defer { center.end(id) }
        let after = Date()
        let started = try? XCTUnwrap(center.items.first?.startedAt)
        XCTAssertNotNil(started)
        if let started {
            XCTAssertGreaterThanOrEqual(started, before.addingTimeInterval(-1))
            XCTAssertLessThanOrEqual(started, after.addingTimeInterval(1))
        }
    }

    func testStartedAtDoesNotChangeOnUpdate() async throws {
        let id = center.begin(title: "T")
        defer { center.end(id) }
        guard let original = center.items.first?.startedAt else {
            XCTFail("startedAt 未填入"); return
        }
        try await Task.sleep(nanoseconds: 100_000_000)   // 0.1s
        center.update(id, progress: 0.5, message: "更新中")
        XCTAssertEqual(center.items.first?.startedAt, original, "startedAt 不应随 update 改变")
    }

    func testUpdateProgressMessageAndBytes() {
        let id = center.begin(title: "下载模型", progress: 0.0)
        defer { center.end(id) }
        center.update(id, progress: 0.5)
        XCTAssertEqual(center.items[0].progress, 0.5)
        center.update(id, message: "连接中")
        XCTAssertEqual(center.items[0].message, "连接中")
        center.update(id, bytes: .init(received: 2048, total: 4096))
        XCTAssertEqual(center.items[0].bytes?.received, 2048)
        XCTAssertEqual(center.items[0].bytes?.total, 4096)
        // 传 nil 保持原值
        center.update(id, progress: 0.8)
        XCTAssertEqual(center.items[0].message, "连接中")
        XCTAssertEqual(center.items[0].bytes?.received, 2048)
    }

    func testEndRemovesItem() {
        let id = center.begin(title: "导入词库")
        XCTAssertEqual(center.items.count, 1)
        center.end(id)
        XCTAssertTrue(center.items.isEmpty)
    }

    func testUpdateWithUnknownIDIsIgnored() {
        let id = center.begin(title: "A")
        defer { center.end(id) }
        let unknown = UUID()
        center.update(unknown, progress: 1.0, message: "x")
        XCTAssertEqual(center.items.count, 1)
        XCTAssertNil(center.items[0].progress)
    }

    func testMultipleItemsStayFlatAndIndependent() {
        let a = center.begin(title: "生成文章", progress: 0.2)
        let b = center.begin(title: "下载模型", tag: "download", progress: 0.0)
        defer {
            center.end(a)
            center.end(b)
        }
        XCTAssertEqual(center.items.count, 2)
        XCTAssertEqual(center.items.map(\.title), ["生成文章", "下载模型"])
        XCTAssertEqual(center.items[1].tag, "download")
        center.update(a, progress: 0.9)
        center.update(b, progress: 0.4)
        XCTAssertEqual(center.items[0].progress, 0.9)
        XCTAssertEqual(center.items[1].progress, 0.4)
        center.end(a)
        XCTAssertEqual(center.items.count, 1)
        XCTAssertEqual(center.items[0].title, "下载模型")
    }

    // MARK: - 托管执行

    func testRunHoldsTaskAndAutoEndsOnCompletion() async {
        let id = center.begin(title: "T")
        let done = expectation(description: "done")
        center.run(id) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await MainActor.run { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 2)
        // 轮询等待 run 的收尾 end 执行
        for _ in 0..<20 where !center.items.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(center.items.isEmpty, "任务完成应自动从中心移除")
    }

    func testCancelRemovesItemAndInvokesOnCancel() async {
        let id = center.begin(title: "下载")
        let cancelled = expectation(description: "cancelled")
        center.run(id, onCancel: {
            cancelled.fulfill()
        }) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        center.cancel(id)
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertTrue(center.items.isEmpty)
    }
}
