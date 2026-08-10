import GRDB
import Foundation

/// World：ECS 顶层容器，持有 database / registry / graph。
/// 所有写入通过 run(_:) 在单个写事务内原子执行；UI 与业务代码不得直接操作组件表。
final class World: @unchecked Sendable {
    let database: AppDatabase
    let registry: EntityRegistry
    let graph: GraphQueries

    init(database: AppDatabase) {
        self.database = database
        self.registry = EntityRegistry(database: database)
        self.graph = GraphQueries(database: database)
    }

    /// 在单个写事务内运行 System：先按 requiresAll 过滤 entity_id，再在事务内执行 execute。
    /// System 抛错则整个事务回滚。
    func run<S: System>(_ system: S, context: S.Context) throws {
        let ids = try registry.filterEntityIDs(requiringAll: S.requiresAll)
        try database.dbWriter.write { db in
            try system.execute(world: self, db: db, entities: ids, context: context)
        }
    }
}
