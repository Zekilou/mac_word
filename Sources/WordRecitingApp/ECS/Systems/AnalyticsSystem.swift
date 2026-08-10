import GRDB
import Foundation

/// AnalyticsSystem 空壳：高级数据分析（heatmap / weak-lemma / 遗忘曲线等），
/// 读 review_event 聚合，写 comp_analytics_cache。
/// @ai: 阶段三填充；当前仅声明 requiresAll 与空 execute。
struct AnalyticsSystem: System {
    static let requiresAll: [ComponentID] = [.reviewEvent]
    typealias Context = Void

    func execute(world: World, db: Database, entities: [EntityID], context: Void) throws {
        // 空操作：AnalyticsModule 协议 + 5 内置模块在阶段三接入
    }
}
