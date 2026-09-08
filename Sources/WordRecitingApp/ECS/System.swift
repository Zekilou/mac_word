import GRDB
import Foundation

/// ECS 系统协议：所有写入通过 System 在 World.run 的事务内执行。
/// execute 收到 db 参数（方案 A），System 通过 world.registry 的 db 版本方法访问数据，
/// 保证整批写入在同一事务内原子完成。
/// @ai: 业务代码禁止绕过 System 直接写 comp_* 表。
protocol System: Sendable {
    associatedtype Context: Sendable
    /// 该 System 只处理同时持有这些组件的 entity。
    /// 为空 = 不依赖 entity 集合（纯 op 驱动）：World.run 会传空数组，不做全表扫描。
    static var requiresAll: [ComponentID] { get }
    /// 在 World.run 开启的写事务内执行。
    func execute(world: World, db: Database, entities: [EntityID], context: Context) throws
}
