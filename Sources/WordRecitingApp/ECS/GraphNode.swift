import Foundation

/// 图节点基类协议。所有 Entity 都必须实现。
/// id 和 kind 不可变；真实字段放 Component 表，不在 Entity 上扩展。
/// @ai: 不得改 id / kind / createdAt 三个属性；新增字段走 Component 机制
protocol GraphNode: Identifiable, Sendable, Codable {
    var id: EntityID { get }
    var kind: NodeKind { get }
    var createdAt: Date { get }
}

// MARK: - 7 Entity structs（空壳，kind 为计算属性）

struct LemmaNode: GraphNode {
    let id: EntityID
    var kind: NodeKind { .lemma }
    let createdAt: Date
}

struct CardNode: GraphNode {
    let id: EntityID
    var kind: NodeKind { .card }
    let createdAt: Date
}

struct DeckNode: GraphNode {
    let id: EntityID
    var kind: NodeKind { .deck }
    let createdAt: Date
}

struct SentenceNode: GraphNode {
    let id: EntityID
    var kind: NodeKind { .sentence }
    let createdAt: Date
}

struct ArticleNode: GraphNode {
    let id: EntityID
    var kind: NodeKind { .article }
    let createdAt: Date
}

struct EventNode: GraphNode {
    let id: EntityID
    var kind: NodeKind { .event }
    let createdAt: Date
}

struct EdgeNode: GraphNode {
    let id: EntityID
    var kind: NodeKind { .edge }
    let createdAt: Date
}

// MARK: - Edge 行（edges 表的拓扑数据，与 EdgeNode 分离）

struct EdgeRecord: Codable, Sendable, Equatable {
    var id: EntityID
    var srcId: EntityID
    var dstId: EntityID
    var relType: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case srcId = "src_id"
        case dstId = "dst_id"
        case relType = "rel_type"
        case createdAt = "created_at"
    }
}
