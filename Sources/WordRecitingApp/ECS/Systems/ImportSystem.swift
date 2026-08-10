import GRDB
import Foundation

/// ImportSystem：在单个写事务内将一个 ImportBatch 落库。
/// 步骤：
///  1. INSERT nodes（deck + 所有 lemma/card）
///  2. UPSERT comp_deck_meta / comp_text / comp_schedule_state
///  3. INSERT edges（has / instantiates）
///  4. 对每个 failure：INSERT EventNode + comp_import_failure + edge(owns: Deck→Event)
/// requiresAll = []：导入不依赖已有 entity，直接用 context 批量写入。
struct ImportSystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = ImportBatch

    func execute(world: World, db: Database, entities: [EntityID], context: ImportBatch) throws {
        let timestamp = context.nodes.first?.createdAt ?? Date()

        // 1. INSERT nodes
        for spec in context.nodes {
            try world.registry.insertNode(
                db, id: spec.id, kind: spec.kind, createdAt: spec.createdAt)
        }

        // 2. UPSERT components
        for dm in context.deckMetas {
            try world.registry.upsertComponent(db, dm)
        }
        for tc in context.textComponents {
            try world.registry.upsertComponent(db, tc)
        }
        for lm in context.lemmaMetas {
            try world.registry.upsertComponent(db, lm)
        }
        for ts in context.tagSets {
            try world.registry.upsertComponent(db, ts)
        }
        for ss in context.scheduleStates {
            try world.registry.upsertComponent(db, ss)
        }

        // 3. INSERT edges
        for spec in context.edges {
            try world.registry.insertEdge(
                db, id: spec.id, srcId: spec.srcId, dstId: spec.dstId,
                rel: spec.rel, createdAt: spec.createdAt)
        }

        // 4. failures → EventNode + comp_import_failure + owns edge
        for f in context.failures {
            try world.registry.insertNode(
                db, id: f.entityId, kind: .event, createdAt: timestamp)
            try world.registry.upsertComponent(db, ImportFailureComponent(
                entityId: f.entityId, deckId: f.deckId, rowIndex: f.rowIndex,
                rawLine: f.rawLine, reason: f.reason))
            try world.registry.insertEdge(
                db, id: "owns-\(f.entityId)", srcId: f.deckId, dstId: f.entityId,
                rel: .owns, createdAt: timestamp)
        }
    }
}
