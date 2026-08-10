import XCTest
import GRDB
@testable import WordRecitingApp

final class DatabaseTests: XCTestCase {

    func testInMemoryDatabase() throws {
        let appDB = try AppDatabase.inMemory()
        XCTAssertNotNil(appDB.dbWriter)
    }

    func testFileDatabase() throws {
        let tmp = NSTemporaryDirectory() + "test_db_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let appDB = try AppDatabase.file(tmp)
        XCTAssertNotNil(appDB.dbWriter)
    }

    func testForeignKeysEnabled() throws {
        let appDB = try AppDatabase.inMemory()
        let result = try appDB.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(result, true)
    }

    func testWALModeForFileDB() throws {
        let tmp = NSTemporaryDirectory() + "test_wal_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let appDB = try AppDatabase.file(tmp)
        let mode = try appDB.dbWriter.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(mode?.lowercased(), "wal")
    }
}
