import Foundation

/// 一次导入批次的数据载体（Importer 输出 → ImportSystem 输入）。
/// 描述要落库的 nodes / 组件 / edges / failures，由 ImportSystem 在单事务内写入。
/// @ai: 兼容 Anki / 纯文本词库的统一中间表示。
struct ImportBatch: Sendable {
    struct NodeSpec: Sendable {
        let id: EntityID
        let kind: NodeKind
        let createdAt: Date
    }

    struct EdgeSpec: Sendable {
        let id: EntityID
        let srcId: EntityID
        let dstId: EntityID
        let rel: EdgeRel
        let createdAt: Date
    }

    struct FailureSpec: Sendable {
        let entityId: EntityID
        let deckId: EntityID
        let rowIndex: Int
        let rawLine: String
        let reason: String
    }

    /// 主 deck id（导入目标，用于批次标识；failures 各自带 deckId）。
    let deckId: EntityID
    /// 所有待插入节点（deck + lemma/card 等）。
    let nodes: [NodeSpec]
    /// 待 upsert 的文本组件（通常对应 card）。
    let textComponents: [TextComponent]
    /// 待 upsert 的 deck 元数据（支持多 deck）。
    let deckMetas: [DeckMetaComponent]
    /// 待 upsert 的调度状态组件。
    let scheduleStates: [ScheduleStateComponent]
    /// 待插入的边（has / instantiates 等）。
    let edges: [EdgeSpec]
    /// 导入失败记录，每条生成 EventNode + comp_import_failure + owns 边。
    let failures: [FailureSpec]
}
