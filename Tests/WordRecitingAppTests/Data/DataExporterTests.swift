import XCTest
import GRDB
@testable import WordRecitingApp

/// DataExporter：数据库备份 + 词汇 CSV 导出。
/// @ai: 用户数据只有一个 sqlite 文件，此前无任何导出入口——本测试守护「备份可用、
///      CSV 可被导入器读回」这两条最低保障。
final class DataExporterTests: XCTestCase {

    private var appDB: AppDatabase!
    private var world: World!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    // MARK: - CSV 转义

    func testCSVEscapePlainValue() {
        XCTAssertEqual(DataExporter.csvEscape("abandon"), "abandon")
    }

    func testCSVEscapeCommaAndQuotes() {
        XCTAssertEqual(DataExporter.csvEscape("a,b"), "\"a,b\"")
        XCTAssertEqual(DataExporter.csvEscape("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testCSVEscapeNewline() {
        XCTAssertEqual(DataExporter.csvEscape("line1\nline2"), "\"line1\nline2\"")
    }

    // MARK: - 词汇 CSV

    func testExportVocabularyHasHeaderAndRows() throws {
        // 先建 lemma 节点 + 文本（markKnown 要求节点已存在；导出的词面来自 comp_text）
        try appDB.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO nodes (id, kind, created_at) VALUES ('lemma:abandon','lemma',?)",
                arguments: [now])
            try db.execute(sql: """
                INSERT INTO comp_text (entity_id, text_a, text_b) VALUES ('lemma:abandon','abandon','放弃')
                """)
        }
        try world.run(UserKnownSystem(), context: .markKnown(
            lemmaId: "lemma:abandon", source: "manual"))

        let csv = try DataExporter.exportVocabularyCSV(world: world)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "lemma,definition,mastery,seen_count,event_count",
                       "表头需与其他导入器识别的列名兼容")
        // 数据行应含词面与释义（末尾换行会 split 出空串，过滤掉）
        XCTAssertEqual(lines.filter { !$0.isEmpty }.count, 2, "应有一行数据")
        XCTAssertTrue(csv.contains("abandon"), "应含词面")
        XCTAssertTrue(csv.contains("放弃"), "应含释义")
    }

    // MARK: - 数据库备份

    /// 备份产物必须是一个**可独立打开**的完整数据库。
    func testBackupProducesOpenableDatabase() throws {
        try appDB.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO nodes (id, kind, created_at) VALUES ('lemma:x','lemma',?)",
                arguments: [now])
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dest) }

        let bytes = try DataExporter.backupDatabase(world: world, to: dest)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        // 用 GRDB 独立打开备份，确认是完整 SQLite 且数据在里面
        let queue = try DatabaseQueue(path: dest.path)
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nodes") ?? 0
        }
        XCTAssertEqual(count, 1, "备份应包含原库数据")
    }

    /// 目标已存在时应覆盖而不是报错（VACUUM INTO 本身要求目标不存在）。
    func testBackupOverwritesExistingFile() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-overwrite-\(UUID().uuidString).sqlite")
        try "stale".write(to: dest, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dest) }

        XCTAssertNoThrow(try DataExporter.backupDatabase(world: world, to: dest))
        let queue = try DatabaseQueue(path: dest.path)
        XCTAssertNoThrow(try queue.read { db in try Int.fetchOne(db, sql: "SELECT 1") })
    }

    func testDefaultBackupFileNameFormat() {
        let name = DataExporter.defaultBackupFileName(
            now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(name.hasPrefix("wordincontxt-backup-"))
        XCTAssertTrue(name.hasSuffix(".sqlite"))
    }
}
