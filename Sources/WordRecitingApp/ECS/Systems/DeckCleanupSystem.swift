import GRDB
import Foundation

/// DeckCleanupSystem：删除「学习目标」——整个词库（deck + 其卡片）或单张卡片。
/// @ai: **只删学习目标，不删全局词汇认知**。按设计「状态与卡片彻底分离」：
///      词库只是「学习目标集合」，而一个词会不会是**全局**认知（跨词库共享）。
///      删掉卡片/词库不等于忘掉这些词——若连 comp_user_known / comp_mastery_belief /
///      comp_word_event 一起删，重新导入同一词库会丢掉全部复习进度。
///      orphan lemma 保留，供词汇页继续展示。
/// @ai: 不可撤销，UI 层必须先二次确认再调本 System。
struct DeckCleanupSystem: System {
    static let requiresAll: [ComponentID] = [.deckMeta]
    typealias Context = DeckCleanupOp

    func execute(
        world: World, db: Database, entities: [EntityID], context: DeckCleanupOp
    ) throws {
        switch context {
        case .delete(let deckId):
            try Self.deleteDeck(world: world, db: db, deckId: deckId)
        case .deleteCard(let cardId):
            try Self.deleteCard(world: world, db: db, cardId: cardId)
        }
    }

    // MARK: - 词库

    /// 删除一个 deck 及其全部卡片（含卡片相关边）。
    static func deleteDeck(
        world: World, db: Database, deckId: EntityID
    ) throws {
        // 1. 该 deck 下所有卡片 id
        let cardIDs = try String.fetchAll(db, sql: """
            SELECT dst_id FROM edges WHERE src_id = ? AND rel_type = 'has'
            """, arguments: [deckId])
        guard !cardIDs.isEmpty else {
            // 没有卡片（空词库）：直接删 deck 节点即可。
            try world.registry.deleteNode(db, id: deckId)
            return
        }

        // 2. 删全部卡片（含各自挂载的边）
        for cardID in cardIDs {
            try deleteCard(world: world, db: db, cardId: cardID)
        }

        // 3. 删 deck 节点（comp_deck_meta 随 CASCADE 清理）
        try world.registry.deleteNode(db, id: deckId)
    }

    // MARK: - 单张卡片

    /// 删除单张卡片：先删其两侧的边，再删卡片节点。Lemma 与掌握度保留。
    static func deleteCard(
        world: World, db: Database, cardId: EntityID
    ) throws {
        // @ai: 边本身也是 node（edges.id FK → nodes.id），必须先按 node 删掉，
        //      否则删卡片后 edges 表会留下指向已删节点的悬空行。
        let edgeIDs = try String.fetchAll(db, sql: """
            SELECT id FROM edges WHERE src_id = ? OR dst_id = ?
            """, arguments: [cardId, cardId])
        for edgeID in edgeIDs {
            try world.registry.deleteNode(db, id: edgeID)
        }
        try world.registry.deleteNode(db, id: cardId)
    }
}

/// DeckCleanupSystem 的上下文操作。
enum DeckCleanupOp: Sendable {
    /// 删除指定词库（含其全部卡片）。
    case delete(deckId: EntityID)
    /// 删除单张卡片（保留 Lemma 与全局掌握度）。
    case deleteCard(cardId: EntityID)
}
