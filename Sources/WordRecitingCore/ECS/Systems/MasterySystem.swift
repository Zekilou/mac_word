import Foundation
import GRDB

/// MasterySystem：把词事件流重放成 BKT 后验概率，写入 comp_mastery_belief。
/// @ai: 事件流是唯一事实来源；重放幂等（同一事件序列 → 同一后验）。
///      requiresAll 为空 = 纯 op 驱动，不依赖 entity 集合（见 World.run）。
struct MasterySystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = MasteryOp

    let parameters: BKTParameters

    init(parameters: BKTParameters = .default) {
        self.parameters = parameters
    }

    func execute(world: World, db: Database, entities: [EntityID], context: MasteryOp) throws {
        switch context {
        case .recompute(let lemmaIds):
            for lemmaId in lemmaIds {
                try recompute(world: world, db: db, lemmaId: lemmaId)
            }

        case .recomputeAll:
            let candidates = try world.registry.filterEntityIDs(db, requiringAll: [.text])
            for entityId in candidates {
                guard try world.registry.fetchNode(db, id: entityId)?.kind == .lemma else { continue }
                try recompute(world: world, db: db, lemmaId: entityId)
            }
        }
    }

    /// 重放单个 Lemma 的全部事件（时间升序）→ 写后验。无事件则不写。
    private func recompute(world: World, db: Database, lemmaId: EntityID) throws {
        let events = try world.graph.wordEvents(db, lemmaId: lemmaId, ascending: true)
        guard !events.isEmpty else { return }

        let band = try world.graph.lemmaFrequency(db, lemmaId: lemmaId)?.band
        let prior = BKTModel.prior(band: band, parameters: parameters)
        let distinctRegions = try world.graph.distinctRegionCount(db, lemmaId: lemmaId)

        let stream = events.compactMap { row -> (kind: WordEventKind, trust: Double)? in
            guard let kind = WordEventKind(rawValue: row.kind) else { return nil }
            return (kind, row.trust)
        }
        let belief = BKTModel.replay(events: stream, prior: prior,
                                     distinctRegions: distinctRegions,
                                     parameters: parameters)

        try world.registry.upsertComponent(db, MasteryBeliefComponent(
            entityId: lemmaId,
            belief: belief,
            opportunities: events.count,
            lastEventAt: events.last?.occurredAt,
            updatedAt: Date(),
            paramsVersion: parameters.version))
    }
}

/// MasterySystem 的上下文操作。
enum MasteryOp: Sendable {
    /// 重算指定 Lemma 的后验。
    case recompute(lemmaIds: [EntityID])
    /// 全量重算（幂等，启动回填 / 参数版本变更时用）。
    case recomputeAll
}
