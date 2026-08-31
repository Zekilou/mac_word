import GRDB
import Foundation

/// SynonymSystem：在单个写事务内管理 maps_to 同义词边。
/// 两种操作（Context 枚举）：
///  - add(from,to,weight,sourceType)：
///    * 先 findMapsToEdgeId 查已有边，存在则幂等不重复插入；
///    * 否则 INSERT maps_to edge + UPSERT comp_edge_weighted。
///  - remove(edgeId) / removePair(a,b)：
///    * DELETE edge 对应的 node（CASCADE 自动删 edges 行 + 组件）。
/// @ai: requiresAll = []（创建/删除新边，不依赖 entity 签名过滤）。
struct SynonymSystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = SynonymOp

    func execute(world: World, db: Database, entities: [EntityID], context: SynonymOp) throws {
        switch context {
        case .add(let from, let to, let weight, let sourceType):
            try addSynonym(world: world, db: db,
                           from: from, to: to,
                           weight: weight, sourceType: sourceType)
        case .removeByEdge(let edgeId):
            try world.registry.deleteNode(db, id: edgeId)
        case .removePair(let a, let b):
            // 双向查找，删除方向匹配的那条；若从 a→b 不存在再查 b→a
            if let eid = try world.registry.deleteEdgeIfPresent(db, srcId: a, dstId: b, rel: .mapsTo) {
                _ = eid
            } else {
                _ = try world.registry.deleteEdgeIfPresent(db, srcId: b, dstId: a, rel: .mapsTo)
            }
        }
    }

    // MARK: - 私有：add 逻辑

    private func addSynonym(
        world: World, db: Database,
        from: EntityID, to: EntityID,
        weight: Double, sourceType: String
    ) throws {
        guard from != to else { return }
        // 1. 幂等：任方向已存在 maps_to 边则不重复插入，仅更新权重
        if let existing = try world.graph.findMapsToEdgeId(db, a: from, b: to) {
            try world.registry.upsertComponent(db, EdgeWeightedComponent(
                entityId: existing, weightDouble: weight, sourceType: sourceType))
            return
        }
        // 2. 验证两端 node 存在（FK 约束兜底，但先查可给出更清晰的错误）
        guard try world.registry.fetchNode(db, id: from) != nil else {
            throw SynonymError.lemmaNotFound(from)
        }
        guard try world.registry.fetchNode(db, id: to) != nil else {
            throw SynonymError.lemmaNotFound(to)
        }
        // 3. INSERT edge（含 kind=edge 的 node）
        let now = Date()
        let edgeId = "syn-\(from)→\(to)-\(UInt64(now.timeIntervalSince1970 * 1000))"
        try world.registry.insertEdge(
            db, id: edgeId, srcId: from, dstId: to,
            rel: .mapsTo, createdAt: now)
        // 4. UPSERT comp_edge_weighted
        try world.registry.upsertComponent(db, EdgeWeightedComponent(
            entityId: edgeId, weightDouble: weight, sourceType: sourceType))
    }
}

// MARK: - Context

/// SynonymSystem 的操作枚举：add / removeByEdge / removePair。
enum SynonymOp: Sendable {
    /// 添加同义词映射：from → to，带权重与来源类型。
    /// 任方向已存在时幂等更新权重，不重复插边。
    case add(from: EntityID, to: EntityID, weight: Double = 1.0, sourceType: String = "user")
    /// 按 edge id 删除（UI 列表每行的删除按钮走这个）。
    case removeByEdge(edgeId: EntityID)
    /// 按 lemma 对删除（任方向匹配那条 maps_to 边）。
    case removePair(a: EntityID, b: EntityID)
}

// MARK: - 错误

enum SynonymError: Error, Sendable, Equatable {
    case lemmaNotFound(EntityID)
}
