import XCTest
import GRDB
@testable import WordRecitingApp

final class AnkiImporterTests: XCTestCase {
    private let toeflPath = "/Users/zekiwithcat/Documents/Obsidian Vault/word_reciting/external_src/400_must_have_words_for_the_TOEFL_.apkg"
    private let grePath = "/Users/zekiwithcat/Documents/Obsidian Vault/word_reciting/external_src/Bing____GRE.apkg"

    private func toeflExists() -> Bool {
        FileManager.default.fileExists(atPath: toeflPath)
    }
    private func greExists() -> Bool {
        FileManager.default.fileExists(atPath: grePath)
    }

    // MARK: - 协议元数据

    func testIdentifierAndExtensions() {
        XCTAssertEqual(AnkiImporter.identifier, "anki")
        XCTAssertTrue(AnkiImporter.supportedExtensions.contains("apkg"))
        XCTAssertTrue(AnkiImporter.supportedExtensions.contains("colpkg"))
    }

    func testCanImportByExtension() {
        let importer = AnkiImporter()
        XCTAssertTrue(importer.canImport(url: URL(fileURLWithPath: "/tmp/test.apkg")))
        XCTAssertTrue(importer.canImport(url: URL(fileURLWithPath: "/tmp/test.APKG")))
        XCTAssertTrue(importer.canImport(url: URL(fileURLWithPath: "/tmp/test.colpkg")))
        XCTAssertFalse(importer.canImport(url: URL(fileURLWithPath: "/tmp/test.csv")))
        XCTAssertFalse(importer.canImport(url: URL(fileURLWithPath: "/tmp/test.zip")))
    }

    // MARK: - 字段映射（不依赖真实 apkg 文件）

    func testRoleForFieldEnglishNames() {
        XCTAssertEqual(AnkiImporter.roleForField("Word"), .headword)
        XCTAssertEqual(AnkiImporter.roleForField("Front"), .headword)
        XCTAssertEqual(AnkiImporter.roleForField("headword"), .headword)
        XCTAssertEqual(AnkiImporter.roleForField("Back"), .definition)
        XCTAssertEqual(AnkiImporter.roleForField("Definition"), .definition)
        XCTAssertEqual(AnkiImporter.roleForField("Phonetic"), .phonetic)
        XCTAssertEqual(AnkiImporter.roleForField("Pronunciation"), .phonetic)
        XCTAssertEqual(AnkiImporter.roleForField("POS"), .pos)
        XCTAssertEqual(AnkiImporter.roleForField("Tags"), .tags)
        XCTAssertEqual(AnkiImporter.roleForField("Example"), .example)
        XCTAssertEqual(AnkiImporter.roleForField("Picture"), .other)
        XCTAssertEqual(AnkiImporter.roleForField("Notes"), .other)
    }

    func testRoleForFieldChineseNames() {
        XCTAssertEqual(AnkiImporter.roleForField("单词"), .headword)
        XCTAssertEqual(AnkiImporter.roleForField("正面"), .headword)
        XCTAssertEqual(AnkiImporter.roleForField("背面"), .definition)
        XCTAssertEqual(AnkiImporter.roleForField("基本释义"), .definition)
        XCTAssertEqual(AnkiImporter.roleForField("音标"), .phonetic)
        XCTAssertEqual(AnkiImporter.roleForField("词性"), .pos)
        XCTAssertEqual(AnkiImporter.roleForField("考纲"), .tags)
        XCTAssertEqual(AnkiImporter.roleForField("例句"), .example)
    }

    func testRoleForFieldSubstringMatch() {
        // 子串匹配（中英文混合名）
        XCTAssertEqual(AnkiImporter.roleForField("Phonetic UK"), .phonetic)
        XCTAssertEqual(AnkiImporter.roleForField("Phonetic US"), .phonetic)
        XCTAssertEqual(AnkiImporter.roleForField("Collins Definition"), .definition)
    }

    func testMapFieldsAllRoles() {
        let m = AnkiImporter.mapFields(
            ["Word", "Definition", "Phonetic", "POS", "Tags", "Example", "Extra"],
            values: ["abandon", "to leave", "ə'bændən", "v.", "hard", "He abandoned ship.", "extra"])
        XCTAssertEqual(m.headword, "abandon")
        XCTAssertEqual(m.definition, "to leave")
        XCTAssertEqual(m.phonetic, "ə'bændən")
        XCTAssertEqual(m.pos, "v.")
        XCTAssertEqual(m.tags, "hard")
        XCTAssertEqual(m.example, "He abandoned ship.")
        XCTAssertEqual(m.sensesJson, "He abandoned ship.")
    }

    func testMapFieldsFallbackToFirstNonEmpty() {
        // 无已知字段名时，headword 回退为第一个非空值
        let m = AnkiImporter.mapFields(["Unknown", "Other"], values: ["hello", "world"])
        XCTAssertEqual(m.headword, "hello")
        XCTAssertNil(m.definition)
    }

    func testMapFieldsSkipsEmptyValues() {
        let m = AnkiImporter.mapFields(["Word", "Back"], values: ["", "定义"])
        // Word 值为空，不应作为 headword；但 headword 回退会取第一个非空 = "定义"
        XCTAssertEqual(m.headword, "定义")
        // Back 字段被映射为 definition
        XCTAssertEqual(m.definition, "定义")
    }

    func testMapFieldsHandlesFewerValuesThanNames() {
        // values 比 names 少：超出范围的字段被忽略
        let m = AnkiImporter.mapFields(["Word", "Back", "Extra"], values: ["hello"])
        XCTAssertEqual(m.headword, "hello")
        XCTAssertNil(m.definition)
    }

    // MARK: - TOEFL 真实文件导入

    func testTOEFLImport() async throws {
        try XCTSkipIf(!toeflExists(), "TOEFL .apkg not found at \(toeflPath)")
        let importer = AnkiImporter()
        var lastProgress: Double = 0
        let batch = try await importer.readNodes(from: URL(fileURLWithPath: toeflPath)) { p in
            lastProgress = p
        }
        // 1 deck + 402 lemma + 402 card = 805
        XCTAssertEqual(batch.nodes.count, 805)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .deck }.count, 1)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .lemma }.count, 402)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .card }.count, 402)
        // 402 (lemma) + 402 (card) = 804
        XCTAssertEqual(batch.textComponents.count, 804)
        XCTAssertEqual(batch.lemmaMetas.count, 402)
        XCTAssertEqual(batch.scheduleStates.count, 402)
        XCTAssertEqual(batch.deckMetas.count, 1)
        // 402 has(Deck→Card) + 402 instantiates(Card→Lemma) = 804
        XCTAssertEqual(batch.edges.count, 804)
        XCTAssertEqual(batch.edges.filter { $0.rel == .has }.count, 402)
        XCTAssertEqual(batch.edges.filter { $0.rel == .instantiates }.count, 402)
        XCTAssertEqual(batch.failures.count, 0)
        // progress 到 1.0
        XCTAssertEqual(lastProgress, 1.0)
        // 验证 "abandon" 出现在导入结果中
        let abandon = batch.textComponents.first { tc in
            (tc.textA ?? "").contains("abandon")
        }
        XCTAssertNotNil(abandon)
        // deck meta 标记为 anki 来源
        XCTAssertEqual(batch.deckMetas.first?.sourceKind, "anki")
        XCTAssertEqual(batch.deckMetas.first?.sourcePath, toeflPath)
        // deckId 是稳定 ID 格式
        XCTAssertTrue(batch.deckId.hasPrefix("anki:deck:"))
    }

    // MARK: - GRE 真实文件导入（只验证数量和抽样）

    func testGREImport() async throws {
        try XCTSkipIf(!greExists(), "GRE .apkg not found at \(grePath)")
        let importer = AnkiImporter()
        let batch = try await importer.readNodes(from: URL(fileURLWithPath: grePath)) { _ in }
        // 1 deck + 18474 lemma + 18474 card = 36949
        XCTAssertEqual(batch.nodes.count, 36949)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .deck }.count, 1)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .lemma }.count, 18474)
        XCTAssertEqual(batch.nodes.filter { $0.kind == .card }.count, 18474)
        // 18474 (lemma) + 18474 (card) = 36948
        XCTAssertEqual(batch.textComponents.count, 36948)
        XCTAssertEqual(batch.scheduleStates.count, 18474)
        XCTAssertEqual(batch.deckMetas.count, 1)
        // 18474 has + 18474 instantiates = 36948
        XCTAssertEqual(batch.edges.count, 36948)
        // GRE 的"考纲"字段被映射为 tags
        XCTAssertGreaterThan(batch.tagSets.count, 0)
        // 验证第一个单词 "a" 出现在导入结果中
        let aWord = batch.textComponents.first { tc in tc.textA == "a" }
        XCTAssertNotNil(aWord)
    }

    // MARK: - 端到端落库（AnkiImporter → ImportBatch → ImportSystem → 验证数据库）

    func testEndToEndWithImportSystem() async throws {
        try XCTSkipIf(!toeflExists(), "TOEFL .apkg not found at \(toeflPath)")
        let importer = AnkiImporter()
        let batch = try await importer.readNodes(from: URL(fileURLWithPath: toeflPath)) { _ in }

        let appDB = try AppDatabase.inMemory()
        let world = World(database: appDB)
        try world.run(ImportSystem(), context: batch)

        // 业务节点（deck + lemma + card），不含 edge 节点：805
        let nodeCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nodes WHERE kind != 'edge'")
        }
        XCTAssertEqual(nodeCount, 805)

        // comp_text: 402 lemma + 402 card = 804
        let textCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_text")
        }
        XCTAssertEqual(textCount, 804)

        // comp_lemma_meta: 402
        let lemmaMetaCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_lemma_meta")
        }
        XCTAssertEqual(lemmaMetaCount, 402)

        // comp_schedule_state: 402
        let schedCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_schedule_state")
        }
        XCTAssertEqual(schedCount, 402)

        // comp_deck_meta: 1
        let deckMetaCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_deck_meta")
        }
        XCTAssertEqual(deckMetaCount, 1)

        // edges: 402 has + 402 instantiates = 804
        let hasEdgeCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE rel_type = 'has'")
        }
        XCTAssertEqual(hasEdgeCount, 402)

        let instEdgeCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE rel_type = 'instantiates'")
        }
        XCTAssertEqual(instEdgeCount, 402)

        // 验证 abandon 已落库
        let abandonText: TextComponent? = try await appDB.dbWriter.read { db in
            try TextComponent.fetchOne(
                db, sql: "SELECT * FROM comp_text WHERE text_a LIKE '%abandon%' LIMIT 1")
        }
        XCTAssertNotNil(abandonText)

        // 验证 schedule queue 都是 "new"（TOEFL 数据全 queue=0）
        let newQueueCount = try await appDB.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comp_schedule_state WHERE queue = 'new'")
        }
        XCTAssertEqual(newQueueCount, 402)
    }

    // MARK: - 错误处理

    func testCannotImportNonApkgFile() async throws {
        let importer = AnkiImporter()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("not-a.apkg.txt")
        try "hello".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try await importer.readNodes(from: tmp) { _ in }
            XCTFail("应抛 unsupportedFile 错误")
        } catch AnkiImportError.unsupportedFile {
            // 预期
        }
    }
}
