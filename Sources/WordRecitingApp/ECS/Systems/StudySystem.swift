import GRDB
import Foundation

/// StudySystem：处理复习调度（SM-2 简化版）。
/// 收到一次评分 → 更新卡片 comp_schedule_state，并落一条 comp_review_event + produces 边。
/// 调度规则（简化 SM-2，够用于 MVP）：
///   - 首次（reps==0）：again→10min、hard→1d、good→3d、easy→7d
///   - 后续：again→重置为 1d 并 lapses+1；其余 interval × factor
///   - factor 初始 2.5，again 时 -0.2（下限 1.3），good/easy 不变，hard -0.15
/// @ai: 只通过 World.run 调用；写入均在本 System 的 db 事务内完成。
struct StudySystem: System {
    static let requiresAll: [ComponentID] = [.scheduleState]
    typealias Context = StudyOp

    /// 单次评分操作。
    struct StudyOp: Sendable {
        let cardId: EntityID
        let rating: Rating
        let reviewedAt: Date
    }

    func execute(world: World, db: Database, entities: [EntityID], context: StudyOp) throws {
        // 读当前调度状态（不存在则按新卡处理）
        let state: ScheduleStateComponent? = try world.registry.fetchComponents(
            db, for: context.cardId, table: "comp_schedule_state")

        let now = context.reviewedAt
        let rating = context.rating

        // 1. 计算新调度参数
        let old = state ?? ScheduleStateComponent(
            entityId: context.cardId, stability: nil, difficulty: nil,
            dueAt: nil, intervalDays: nil, reps: 0, lapses: 0,
            lastRating: nil, lastReviewedAt: nil, schedulerId: "sm-2",
            queue: "new", customDataJson: nil)

        let reps = (old.reps ?? 0) + 1
        var lapses = old.lapses ?? 0
        var factor = old.difficulty ?? 2.5
        var interval: Double
        let previousInterval = old.intervalDays ?? 0

        if reps == 1 {
            // 首次
            switch rating {
            case .again: interval = 10.0 / 1440.0  // 10 分钟
            case .hard: interval = 1
            case .good: interval = 3
            case .easy: interval = 7
            }
        } else {
            switch rating {
            case .again:
                interval = 1
                lapses += 1
                factor = max(1.3, factor - 0.2)
            case .hard:
                interval = previousInterval * max(1.3, factor - 0.15)
            case .good:
                interval = previousInterval * factor
            case .easy:
                interval = previousInterval * factor * 1.3
            }
        }

        // 2. 更新 schedule_state
        let newState = ScheduleStateComponent(
            entityId: context.cardId,
            stability: interval,
            difficulty: factor,
            dueAt: now.addingTimeInterval(interval * 86400),
            intervalDays: interval,
            reps: reps,
            lapses: lapses,
            lastRating: rating.rawValue,
            lastReviewedAt: now,
            schedulerId: "sm-2",
            queue: interval < 1 ? "learning" : "review",
            customDataJson: nil)
        try world.registry.upsertComponent(db, newState)

        // 3. 写 review_event（节点 + 组件 + produces 边）
        let eventId = "review-\(UUID().uuidString)"
        try world.registry.insertNode(db, id: eventId, kind: .event, createdAt: now)
        try world.registry.upsertComponent(db, ReviewEventComponent(
            entityId: eventId,
            targetCardId: context.cardId,
            ratedAt: now,
            rating: rating.rawValue,
            respondedMs: nil,
            elapsedDays: previousInterval,
            scheduledInterval: interval,
            deltaStability: interval - previousInterval,
            deltaDifficulty: factor - (old.difficulty ?? 2.5),
            lastIvl: previousInterval,
            factor: factor))
        try world.registry.insertEdge(
            db, id: "prod-\(eventId)",
            srcId: context.cardId, dstId: eventId,
            rel: .produces, createdAt: now)
    }
}
