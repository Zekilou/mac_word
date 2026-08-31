import Foundation
import Observation

/// 全局活动中心（进程守护）：耗时任务（生成文章 / 下载模型 / 导入词库等）统一在此注册并托管执行，
/// 以可配置的进度/状态项展示在窗口顶部状态条上。
/// @ai: @MainActor 单例；业务代码只调 begin/update/end/run/cancel；UI 只读 items，不直接改。
/// **托管保证：run() 启动的任务由中心持有，不随发起方 View/ViewModel 销毁而终止。**
@MainActor
@Observable
final class GlobalActivityCenter {

    static let shared = GlobalActivityCenter()
    private init() {}

    /// 单个活动项：一条可配置的进度 / 状态。
    struct Item: Identifiable, Equatable {
        let id: UUID
        var title: String
        var icon: String?
        /// 可选分类标签（如 "download"），便于 UI 定位特定类型任务。
        var tag: String?
        /// 确定进度 0...1；nil 表示不确定进度（旋转指示器）。
        var progress: Double?
        /// 当前阶段 / 补充状态文字。
        var message: String?
        /// 可选字节进度（下载等场景）。
        var bytes: Bytes?
        /// 开始时间（begin 时自动填入，详细面板显示运行时长）。
        var startedAt: Date
    }

    /// 字节进度。
    struct Bytes: Equatable, Sendable {
        let received: Int64
        let total: Int64
    }

    private(set) var items: [Item] = []

    /// 执行侧：托管的长任务句柄（保证不随 View/VM 销毁）。
    private var executions: [UUID: Task<Void, Never>] = [:]
    /// 取消回调（如下载器的 cancel）。
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    // MARK: - 注册 / 展示

    /// 注册一个新活动项，返回其 id（供 update / end / run / cancel 使用）。
    @discardableResult
    func begin(
        title: String,
        icon: String? = nil,
        tag: String? = nil,
        progress: Double? = nil,
        message: String? = nil,
        bytes: Bytes? = nil
    ) -> UUID {
        let id = UUID()
        items.append(Item(
            id: id, title: title, icon: icon, tag: tag,
            progress: progress, message: message, bytes: bytes,
            startedAt: Date()))
        return id
    }

    /// 更新某个活动项的进度 / 状态；对应参数传 nil 表示保持原值。
    func update(
        _ id: UUID,
        progress: Double? = nil,
        message: String? = nil,
        bytes: Bytes? = nil
    ) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let progress { items[i].progress = progress }
        if let message { items[i].message = message }
        if let bytes { items[i].bytes = bytes }
    }

    /// 结束并移除某个活动项（取消其托管执行）。
    func end(_ id: UUID) {
        cancel(id)
    }

    // MARK: - 托管执行

    /// 托管启动一个长任务：任务由中心持有，即使发起方 View/ViewModel 销毁也继续执行；
    /// operation 返回后自动 end（被 cancel 除外）。
    /// - Parameters:
    ///   - id: 由 begin 返回的任务 id。
    ///   - onCancel: 主动取消时的清理回调（如取消 URLSession 下载）。
    ///   - operation: 任务体（必须完全独立，不依赖发起方对象生命周期）。
    func run(
        _ id: UUID,
        onCancel: (@Sendable () -> Void)? = nil,
        _ operation: @escaping @Sendable () async -> Void
    ) {
        if let onCancel { cancellations[id] = onCancel }
        executions[id] = Task { [weak self] in
            await operation()
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.end(id) }
        }
    }

    /// 主动取消一个任务：调用其取消回调并移除展示项。
    func cancel(_ id: UUID) {
        cancellations[id]?()
        cancellations.removeValue(forKey: id)
        executions.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
    }
}
