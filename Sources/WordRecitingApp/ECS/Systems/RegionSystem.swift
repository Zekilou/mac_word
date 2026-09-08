import Foundation
import GRDB

/// RegionSystem：管理「显示词汇的上下文」并全量记录词事件。
/// @ai: 一次 record 会先幂等 upsert region，再为每个 lemma 落一个事件节点 + 组件 + 两条边。
///      event.trust = override ?? region.trust —— 被动 region 内的主动交互可提升可信度。
struct RegionSystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = RegionOp

    func execute(world: World, db: Database, entities: [EntityID], context: RegionOp) throws {
        switch context {
        case .ensure(let ref):
            try ensureRegion(world: world, db: db, ref: ref)

        case .record(let lemmaIds, let ref, let kind, let override, let detail):
            try ensureRegion(world: world, db: db, ref: ref)
            let now = Date()
            let trust = override ?? ref.trust
            for lemmaId in lemmaIds {
                guard try world.registry.fetchNode(db, id: lemmaId) != nil else { continue }
                let eventId = "word-event-\(UUID().uuidString)"
                try world.registry.insertNode(db, id: eventId, kind: .event, createdAt: now)
                try world.registry.upsertComponent(db, WordEventComponent(
                    entityId: eventId,
                    lemmaId: lemmaId,
                    regionId: ref.id,
                    eventKind: kind.rawValue,
                    trust: trust,
                    occurredAt: now,
                    detailJson: detail))
                try world.registry.insertEdge(db, id: "we-lemma-\(eventId)",
                                              srcId: lemmaId, dstId: eventId,
                                              rel: .produces, createdAt: now)
                try world.registry.insertEdge(db, id: "we-region-\(eventId)",
                                              srcId: ref.id, dstId: eventId,
                                              rel: .contains, createdAt: now)
            }
        }
    }

    /// 幂等：region 节点不存在才建；组件始终按最新描述覆盖。
    private func ensureRegion(world: World, db: Database, ref: RegionRef) throws {
        if try world.registry.fetchNode(db, id: ref.id) == nil {
            try world.registry.insertNode(db, id: ref.id, kind: .region, createdAt: Date())
        }
        try world.registry.upsertComponent(db, RegionComponent(
            entityId: ref.id,
            kind: ref.kind.rawValue,
            label: ref.label,
            sourceId: ref.sourceId,
            trust: ref.trust,
            createdAt: Date()))
    }
}

/// Region 引用描述。id 由业务键构造，保证同一上下文复用同一 region。
struct RegionRef: Sendable, Equatable {
    let id: EntityID
    let kind: RegionKind
    let label: String?
    let sourceId: EntityID?
    /// 该上下文的基础可信度：主动上下文 1.0，被动上下文 0.0。
    let trust: Double

    static func study(cardId: EntityID) -> RegionRef {
        RegionRef(id: "region-study-\(cardId)", kind: .study,
                  label: nil, sourceId: cardId, trust: 1.0)
    }

    static func rss(articleId: EntityID, title: String?) -> RegionRef {
        RegionRef(id: "region-rss-\(articleId)", kind: .rss,
                  label: title, sourceId: articleId, trust: 0.0)
    }

    static func generate(articleId: EntityID, title: String?) -> RegionRef {
        RegionRef(id: "region-generate-\(articleId)", kind: .generate,
                  label: title, sourceId: articleId, trust: 0.0)
    }

    static func dictionary() -> RegionRef {
        RegionRef(id: "region-dictionary", kind: .dictionary,
                  label: nil, sourceId: nil, trust: 1.0)
    }

    static func initSession(sessionId: EntityID) -> RegionRef {
        RegionRef(id: "region-init-\(sessionId)", kind: .initSession,
                  label: nil, sourceId: sessionId, trust: 1.0)
    }
}

/// RegionSystem 的上下文操作。
enum RegionOp: Sendable {
    /// 仅确保 region 存在（例如进入页面时先登记）。
    case ensure(RegionRef)
    /// 记录一次/一批词事件；`trust` 非 nil 时覆盖 region 基础可信度。
    case record(lemmaIds: [EntityID], region: RegionRef,
                kind: WordEventKind, trust: Double?, detail: String?)
}
