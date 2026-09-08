import Foundation
import GRDB

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

/// 句子节点（设计文档 §3.2 规划的 7 个 Entity struct 之一）。
/// 阶段一仅作图模型骨架占位，无业务引用；规划语义：Tatoeba 导入器生成 SentenceNode + appears_in 边
/// （§10.14），ContentGenSystem 产文时拆分成 N × SentenceNode（§8.2）。
/// @ai: 属规划骨架，勿删（删除会破坏 ECS 图模型 7 Entity 完整性）。
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

struct EdgeRecord: Codable, FetchableRecord, Sendable, Equatable {
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
