import GRDB
import Foundation

/// AnalyticsSystem（设计文档 §2 / §3.6 规划的 4 大 System 之一：Import/Study/ContentGen/Analytics）。
/// 阶段一只做空壳占位（声明 requiresAll + 空 execute）；阶段三填充：
/// AnalyticsModule 协议 + 5 内置模块（heatmap / 遗忘曲线 / weak-lemma / 负载预测 / FSRS 拟合），
/// 读 review_event 聚合，写 comp_analytics_cache（§10.19）。
/// @ai: 阶段三接入，勿删，属规划骨架。
struct AnalyticsSystem: System {
    static let requiresAll: [ComponentID] = [.reviewEvent]
    typealias Context = Void

    func execute(world: World, db: Database, entities: [EntityID], context: Void) throws {
        // 空操作：AnalyticsModule 协议 + 5 内置模块在阶段三接入
    }
}
