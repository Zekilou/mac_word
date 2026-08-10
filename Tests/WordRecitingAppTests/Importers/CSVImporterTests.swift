import XCTest
@testable import WordRecitingApp

final class CSVImporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeCSV(_ content: String, name: String = "test.csv") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 协议元数据

    func testIdentifierAndExtensions() {
        XCTAssertEqual(CSVImporter.identifier, "csv")
        XCTAssertTrue(CSVImporter.supportedExtensions.contains("csv"))
    }

    func testCanImportByExtension() throws {
        let importer = CSVImporter()
        XCTAssertTrue(importer.canImport(url: tempDir.appendingPathComponent("a.csv")))
        XCTAssertTrue(importer.canImport(url: tempDir.appendingPathComponent("a.CSV")))
        XCTAssertTrue(importer.canImport(url: tempDir.appendingPathComponent("a.tsv")))
        XCTAssertFalse(importer.canImport(url: tempDir.appendingPathComponent("a.json")))
    }

    // MARK: - 核心：5 行有效 + 1 行错行

    func testParseFiveRowsPlusOneFailure() async throws {
        let csv = """
        front,back,lemma,pos
        abandon,放弃,abandon,v.
        forsake,放弃,forsake,v.
        leave,离开,leave,v.
        happy,快乐,happy,adj.
        sad,悲伤,sad,adj.
        ,,
        """
        let url = try writeCSV(csv, name: "test.csv")
        let importer = CSVImporter()
        var progressValues: [Double] = []
        let batch = try await importer.readNodes(from: url) { p in
            progressValues.append(p)
        }

        // deckId 由文件名生成
        XCTAssertEqual(batch.deckId, "deck-test")
        // 1 deck + 5 lemma + 5 card = 11
        XCTAssertEqual(batch.nodes.count, 11)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .deck }.count, 1)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .lemma }.count, 5)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .card }.count, 5)
        // 5 lemma meta + 5 text (lemma) + 5 schedule (card) + 1 deck meta
        XCTAssertEqual(batch.lemmaMetas.count, 5)
        XCTAssertEqual(batch.textComponents.count, 5)
        XCTAssertEqual(batch.scheduleStates.count, 5)
        XCTAssertEqual(batch.deckMetas.count, 1)
        // edges: 5 has(Deck→Card) + 5 has(Deck→Lemma) + 5 instantiates(Card→Lemma) = 15
        XCTAssertEqual(batch.edges.count, 15)
        XCTAssertEqual(batch.edges.filter { $0.rel == .has }.count, 10)
        XCTAssertEqual(batch.edges.filter { $0.rel == .instantiates }.count, 5)
        // 1 failure
        XCTAssertEqual(batch.failures.count, 1)
        XCTAssertEqual(batch.failures.first?.deckId, "deck-test")
        // progress 已回调，最后为 1.0
        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertEqual(progressValues.last, 1.0)
    }

    // MARK: - 仅 front/back 列

    func testOnlyFrontBackColumns() async throws {
        let csv = """
        front,back
        hello,你好
        world,世界
        """
        let url = try writeCSV(csv, name: "simple.csv")
        let importer = CSVImporter()
        let batch = try await importer.readNodes(from: url) { _ in }

        // 1 deck + 2 card（无 lemma）
        XCTAssertEqual(batch.nodes.count, 3)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .card }.count, 2)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .lemma }.count, 0)
        // 2 text (card) + 2 schedule + 1 deck meta
        XCTAssertEqual(batch.textComponents.count, 2)
        XCTAssertEqual(batch.scheduleStates.count, 2)
        // 2 has(Deck→Card)
        XCTAssertEqual(batch.edges.count, 2)
        XCTAssertEqual(batch.edges.filter { $0.rel == .has }.count, 2)
        // 无失败
        XCTAssertEqual(batch.failures.count, 0)
    }

    // MARK: - 分隔符自动识别（Tab）

    func testTabDelimiterDetection() async throws {
        let csv = "front\tback\nhello\t你好\n"
        let url = try writeCSV(csv, name: "tab.tsv")
        let importer = CSVImporter()
        let batch = try await importer.readNodes(from: url) { _ in }

        // 1 deck + 1 card
        XCTAssertEqual(batch.nodes.count, 2)
        XCTAssertEqual(batch.textComponents.count, 1)
        XCTAssertEqual(batch.textComponents.first?.textA, "hello")
        XCTAssertEqual(batch.textComponents.first?.textB, "你好")
    }

    // MARK: - deck 元数据

    func testDeckMetaContainsFilename() async throws {
        let csv = "front,back\nhello,你好\n"
        let url = try writeCSV(csv, name: "mywords.csv")
        let importer = CSVImporter()
        let batch = try await importer.readNodes(from: url) { _ in }
        XCTAssertEqual(batch.deckId, "deck-mywords")
        XCTAssertEqual(batch.deckMetas.first?.name, "mywords")
        XCTAssertEqual(batch.deckMetas.first?.sourceKind, "csv")
        XCTAssertEqual(batch.deckMetas.first?.sourcePath, url.path)
    }

    // MARK: - comp_schedule_state 默认值

    func testScheduleStateDefaults() async throws {
        let csv = "front,back\nhello,你好\n"
        let url = try writeCSV(csv, name: "defaults.csv")
        let importer = CSVImporter()
        let batch = try await importer.readNodes(from: url) { _ in }
        let ss = try XCTUnwrap(batch.scheduleStates.first)
        XCTAssertEqual(ss.stability, 0)
        XCTAssertEqual(ss.difficulty, 0)
        XCTAssertEqual(ss.reps, 0)
        XCTAssertEqual(ss.lapses, 0)
        XCTAssertEqual(ss.queue, "new")
        XCTAssertNotNil(ss.dueAt)
    }

    // MARK: - lemma + pos 内容正确

    func testLemmaMetaPosAndTextContent() async throws {
        let csv = "front,back,lemma,pos\nabandon,放弃,abandon,v.\n"
        let url = try writeCSV(csv, name: "lemma.csv")
        let importer = CSVImporter()
        let batch = try await importer.readNodes(from: url) { _ in }
        let lm = try XCTUnwrap(batch.lemmaMetas.first)
        XCTAssertEqual(lm.pos, "v.")
        let tc = try XCTUnwrap(batch.textComponents.first)
        XCTAssertEqual(tc.textA, "abandon")
        XCTAssertEqual(tc.textB, "放弃")
    }

    // MARK: - 端到端落库（CSVImporter → ImportSystem）

    func testEndToEndImportIntoDatabase() async throws {
        let csv = """
        front,back,lemma,pos
        abandon,放弃,abandon,v.
        happy,快乐,happy,adj.
        """
        let url = try writeCSV(csv, name: "e2e.csv")
        let importer = CSVImporter()
        let batch = try await importer.readNodes(from: url) { _ in }

        let appDB = try AppDatabase.inMemory()
        let world = World(database: appDB)
        try world.run(ImportSystem(), context: batch)

        // 节点：1 deck + 2 lemma + 2 card = 5
        let nodeCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nodes WHERE kind != 'edge'")
        }
        XCTAssertEqual(nodeCount, 5)
        let lemmaMetaCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_lemma_meta")
        }
        XCTAssertEqual(lemmaMetaCount, 2)
        let instCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE rel_type = 'instantiates'")
        }
        XCTAssertEqual(instCount, 2)
    }

    // MARK: - 错误处理

    func testEmptyFileThrows() async throws {
        let url = try writeCSV("", name: "empty.csv")
        let importer = CSVImporter()
        do {
            _ = try await importer.readNodes(from: url) { _ in }
            XCTFail("应抛 emptyFile 错误")
        } catch CSVImportError.emptyFile {
            // 预期
        }
    }

    func testUnrecognizedHeadersThrow() async throws {
        let csv = "foo,bar\nbaz,qux\n"
        let url = try writeCSV(csv, name: "bad.csv")
        let importer = CSVImporter()
        do {
            _ = try await importer.readNodes(from: url) { _ in }
            XCTFail("应抛 unrecognizedFormat 错误")
        } catch CSVImportError.unrecognizedFormat {
            // 预期
        }
    }
}
