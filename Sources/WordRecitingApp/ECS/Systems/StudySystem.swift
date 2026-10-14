import GRDB
import Foundation

/// StudySystem：处理复习调度。
/// 收到一次评分 → 交给排期策略算新状态 → 写 comp_schedule_state，并落一条 comp_review_event + produces 边。
/// 具体间隔公式见 `ReviewIntervalPolicy` 实现（默认 `.sm2` 即原简化 SM-2）。
/// @ai: 只通过 World.run 调用；写入均在本 System 的 db 事务内完成。
struct StudySystem: System {
    static let requiresAll: [ComponentID] = [.scheduleState]
    typealias Context = StudyOp

    /// 单次评分操作。
    struct StudyOp: Sendable {
        let cardId: EntityID
        let rating: Rating
        let reviewedAt: Date
        /// 排期策略（由 StudyViewModel 从设置读入——System 不碰 UI/设置）。
        var policyID: SchedulerID = .sm2
    }

    func execute(world: World, db: Database, entities: [EntityID], context: StudyOp) throws {
        // 读当前调度状态（不存在则按新卡处理）
        let state: ScheduleStateComponent? = try world.registry.fetchComponents(
            db, for: context.cardId, table: "comp_schedule_state")

        let now = context.reviewedAt
        let rating = context.rating

        let old = state ?? ScheduleStateComponent(
            entityId: context.cardId, stability: nil, difficulty: nil,
            dueAt: nil, intervalDays: nil, reps: 0, lapses: 0,
            lastRating: nil, lastReviewedAt: nil, schedulerId: "sm-2",
            queue: "new", customDataJson: nil)

        // 词元特征（供策略消费词频/概率）；取不到就给空特征。
        let features: WordFeatures
        if let lemmaId = try world.graph.lemmaIdForCard(db, cardId: context.cardId),
           let found = try world.graph.wordFeatures(db, lemmaIds: [lemmaId])[lemmaId] {
            features = found
        } else {
            features = WordFeatures(lemmaId: context.cardId, belief: nil, band: nil, rank: nil,
                                    eventCount: 0, contextCount: 0,
                                    lastEventAt: nil, card: nil)
        }

        // 1+2. 交给策略算新状态并写回
        let policy = SchedulingRegistry.reviewPolicy(context.policyID)
        let newState = policy.next(state: old, rating: rating,
                                   features: features, now: now)
        try world.registry.upsertComponent(db, newState)

        let interval = newState.intervalDays ?? 0
        let previousInterval = old.intervalDays ?? 0

        // 3. 写 review_event（节点 + 组件 + produces 边）
        let eventId = "review-\(UUID().uuidString)"
        try world.registry.insertNode(db, id: eventId, kind: .event, createdAt: now)
        // @ai: `elapsedDays` 语义是「距上次复习的真实天数」（遗忘曲线的横轴）。
        //      旧实现写的是 `previousInterval`（**计划**间隔）→ 与 lastIvl 完全重复，
        //      复习晚了 30 天的词会被画进它「计划」的 7 天桶里，曲线失真、不是遗忘曲线。
        //      这里用 `now - lastReviewedAt` 计算真实经过天数；首次复习（无上次记录）为 nil。
        let elapsedDays: Double?
        if let last = old.lastReviewedAt {
            elapsedDays = max(0, now.timeIntervalSince(last) / 86400.0)
        } else {
            elapsedDays = nil
        }
        try world.registry.upsertComponent(db, ReviewEventComponent(
            entityId: eventId,
            targetCardId: context.cardId,
            ratedAt: now,
            rating: rating.rawValue,
            respondedMs: nil,
            elapsedDays: elapsedDays,
            scheduledInterval: interval,
            deltaStability: interval - previousInterval,
            deltaDifficulty: (newState.difficulty ?? 2.5) - (old.difficulty ?? 2.5),
            lastIvl: previousInterval,
            factor: newState.difficulty ?? 2.5))
        try world.registry.insertEdge(
            db, id: "prod-\(eventId)",
            srcId: context.cardId, dstId: eventId,
            rel: .produces, createdAt: now)
    }
}
