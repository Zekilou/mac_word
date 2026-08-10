import GRDB
import Foundation

/// StudySystem 空壳：处理复习调度（FSRS/SM-2 更新 schedule_state、产出 review_event）。
/// @ai: 阶段二填充实际逻辑；当前仅声明 requiresAll 与空 execute。
struct StudySystem: System {
    static let requiresAll: [ComponentID] = [.scheduleState]
    typealias Context = Void

    func execute(world: World, db: Database, entities: [EntityID], context: Void) throws {
        // 空操作：阶段二实现调度算法与复习事件落库
    }
}
