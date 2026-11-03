import GRDB
import Foundation

/// GRDB 数据库包装。提供 in-memory 与 file 两种工厂方法，启动时自动跑迁移。
public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        let db = AppDatabase(dbWriter: queue)
        try db.runMigrations()
        return db
    }

    public static func file(_ path: String) throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: path, configuration: config)
        let db = AppDatabase(dbWriter: queue)
        try db.runMigrations()
        return db
    }

    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    func runMigrations() throws {
        try SchemaMigrator.migrate(dbWriter)
    }
}
