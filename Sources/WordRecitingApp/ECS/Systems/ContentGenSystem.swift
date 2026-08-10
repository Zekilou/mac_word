import GRDB
import Foundation

/// ContentGenSystem 空壳：内容生成管线重心（造文/改写），读 maps_to 同义词边，
/// 产出 ArticleNode + highlighted_in/appears_in edges + comp_edge_span。
/// @ai: 阶段一 Task 10-12 填充；当前仅声明 requiresAll 与空 execute。
struct ContentGenSystem: System {
    static let requiresAll: [ComponentID] = [.lemmaMeta]
    typealias Context = Void

    func execute(world: World, db: Database, entities: [EntityID], context: Void) throws {
        // 空操作：ContentGenerator 协议 + RuleBasedGenerator 在 Task 10-12 接入
    }
}
