import GRDB
import Foundation

/// ArticleCleanupSystem：清空全部生成历史文章（generate + rewrite 两模式一起）。
/// 单事务内两步：
///  1. 先删所有指向文章的边（highlighted_in / appears_in 等，edges 行随 nodes CASCADE 删除）
///  2. 再删文章节点（comp_text / comp_generation_meta 组件随 CASCADE 删除）
/// @ai: 所有写入通过 World.run；requiresAll = [.generationMeta]（只清有落库记录的文章）。
struct ArticleCleanupSystem: System {
    static let requiresAll: [ComponentID] = [.generationMeta]
    typealias Context = Void

    func execute(world: World, db: Database, entities: [EntityID], context: Void) throws {
        guard !entities.isEmpty else { return }

        // 1. 删除指向文章的全部边节点（边的 comp_* 组件随 node CASCADE 清理）
        let edgeIDs = try String.fetchAll(db, sql: """
            SELECT e.id FROM edges e
            WHERE e.dst_id IN (SELECT entity_id FROM comp_generation_meta)
            """)
        for edgeID in edgeIDs {
            try world.registry.deleteNode(db, id: edgeID)
        }

        // 2. 删除文章节点本身
        for articleID in entities {
            try world.registry.deleteNode(db, id: articleID)
        }
    }
}
