import XCTest
import GRDB
@testable import WordRecitingApp

/// 通用文本清洗测试：Anki 富文本（HTML/媒体标记/实体）→ 可读纯文本。
/// @ai: GraphQueries 输出层统一调用 TextSanitizer.clean，本测试守护清洗正确性与旧数据兜底。
final class TextSanitizerTests: XCTestCase {

    // MARK: - cleanDefinition（释义：保留换行）

    func testStripsHTMLTags() {
        let raw = "(v) : to leave; to give up<div><div><font color=\"#0055ff\"><i>Ex</i>: <i>Example</i></font></div></div>"
        let out = TextSanitizer.clean(raw, preserveLineBreaks: true)
        XCTAssertEqual(out, "(v): to leave; to give up\nEx: Example")
    }

    func testBRAndDivBecomeLineBreaks() {
        let raw = "(n) fight<br /><div>Ex: He fought bravely.</div>"
        let out = TextSanitizer.clean(raw, preserveLineBreaks: true)
        XCTAssertEqual(out, "(n) fight\nEx: He fought bravely.")
    }

    func testDecodesEntitiesAndSoundMarker() {
        let raw = "n.&nbsp; Water &amp; soil<br />[sound:abandon_400.mp3]"
        let out = TextSanitizer.clean(raw, preserveLineBreaks: true)
        XCTAssertEqual(out, "n. Water & soil")
    }

    func testCollapsesWhitespacePerLine() {
        let raw = "adj.   Extremely   harmful<br />  Ex:  A   long   example  here.  "
        let out = TextSanitizer.clean(raw, preserveLineBreaks: true)
        XCTAssertEqual(out, "adj. Extremely harmful\nEx: A long example here.")
    }

    func testEmptyOrJunkReturnsNil() {
        XCTAssertNil(TextSanitizer.clean(nil, preserveLineBreaks: true))
        XCTAssertNil(TextSanitizer.clean("", preserveLineBreaks: true))
        XCTAssertNil(TextSanitizer.clean("<div><font color=\"#fff\"></font></div>", preserveLineBreaks: true))
    }

    // MARK: - cleanInline（词面：全折叠单行）

    func testInlineCollapsesEverythingToOneLine() {
        let raw = "abandon<div>[sound:abandon_400.mp3]</div><br />"
        let out = TextSanitizer.clean(raw, preserveLineBreaks: false)
        XCTAssertEqual(out, "abandon")
    }

    func testInlineKeepsPhraseWords() {
        let raw = "take&nbsp;&nbsp;up<br /><i>phrasal</i>"
        let out = TextSanitizer.clean(raw, preserveLineBreaks: false)
        XCTAssertEqual(out, "take up phrasal")
    }

    // MARK: - 集成：GraphQueries 输出层清洗（旧脏数据兜底）

    /// @ai: 模拟旧导入的脏 HTML 释义（清洗功能之前的 TOEFL 数据形态）→ 查询返回应为可读纯文本。
    func testCardsInDeckReturnsSanitizedDefinition() async throws {
        let appDB = try AppDatabase.inMemory()
        let world = World(database: appDB)
        let graph = world.graph

        let now = Date()
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "deck-1", kind: .deck, createdAt: now),
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
                .init(id: "card-1", kind: .card, createdAt: now),
            ],
            textComponents: [
                TextComponent(entityId: "lemma-1", textA: "abandon<div>[sound:abandon_400.mp3]</div>",
                              textB: "(v) : to leave<div><font color=\"#0055ff\"><i>Ex</i>: <i>Give up</i></font></div>",
                              language: nil),
                TextComponent(entityId: "card-1", textA: "abandon", textB: nil, language: nil),
            ],
            deckMetas: [DeckMetaComponent(entityId: "deck-1", name: "T", sourceKind: "csv", sourcePath: nil, importedAt: now)],
            edges: [
                .init(id: "e1", srcId: "deck-1", dstId: "card-1", rel: .has, createdAt: now),
                .init(id: "e2", srcId: "card-1", dstId: "lemma-1", rel: .instantiates, createdAt: now),
            ],
            failures: [])
        try world.run(ImportSystem(), context: batch)

        let cards = try graph.cardsInDeck("deck-1")
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.definition, "(v): to leave\nEx: Give up",
                       "脏 HTML 释义应在查询层清洗：\(card.definition ?? "nil")")
        XCTAssertEqual(card.text, "abandon", "词面应清洗媒体/标签残留")
    }
    // MARK: - cleanHeadword（词面：清洗 + 剥音标/词性尾巴）

    /// @ai: 回归 — 脏 headword 曾让词频表完全匹配不上。
    ///      `abandon<div>[sound:…]</div><div>[ə'bændən]</div>` 必须变成 `abandon`。
    func testCleanHeadwordStripsHTMLAndBracketPhonetic() {
        let raw = "abandon<div>[sound:abandon_400.mp3]</div><div>[\u{0259}'b\u{00E6}nd\u{0259}n]</div>"
        XCTAssertEqual(TextSanitizer.cleanHeadword(raw), "abandon")
    }

    /// 斜杠音标：另一批词库的写法 `rotate /rou'teit/`。
    func testCleanHeadwordStripsSlashPhonetic() {
        XCTAssertEqual(TextSanitizer.cleanHeadword("rotate /rou'teit/"), "rotate")
        XCTAssertEqual(TextSanitizer.cleanHeadword("solar /'soul\u{0259}/"), "solar")
    }

    /// 词性括注尾巴：`collapse (v)` → `collapse`。
    func testCleanHeadwordStripsPosAnnotation() {
        XCTAssertEqual(TextSanitizer.cleanHeadword("collapse (v)"), "collapse")
    }

    /// 不误伤：真实含斜杠/空格的词必须原样保留。
    func testCleanHeadwordKeepsLegitimateSlashAndPhrases() {
        XCTAssertEqual(TextSanitizer.cleanHeadword("and/or"), "and/or")
        XCTAssertEqual(TextSanitizer.cleanHeadword("24/7"), "24/7")
        XCTAssertEqual(TextSanitizer.cleanHeadword("per capita"), "per capita")
        XCTAssertEqual(TextSanitizer.cleanHeadword("be inclined to"), "be inclined to")
    }

    /// 空/纯尾巴输入不能让词面消失。
    func testCleanHeadwordDoesNotEraseContent() {
        XCTAssertNil(TextSanitizer.cleanHeadword(nil))
        XCTAssertNil(TextSanitizer.cleanHeadword("   "))
    }

    // MARK: - 存量数据清洗迁移（v7/v8/v9）

    /// @ai: 回归 — 用户库里 TOEFL 词库导入早于清洗逻辑，存量词面是脏 HTML。
    ///      迁移必须就地洗净，否则词频/CEFR/选词分层对这批词全部失效。
    func testStoredTextSanitizerCleansExistingRows() async throws {
        let appDB = try AppDatabase.inMemory()
        let world = World(database: appDB)
        let now = Date()

        // 模拟旧数据：脏词面 + 脏释义 + 带音标尾巴的词面
        let batch = ImportBatch(
            deckId: "deck-1",
            nodes: [
                .init(id: "lemma-1", kind: .lemma, createdAt: now),
                .init(id: "lemma-2", kind: .lemma, createdAt: now),
            ],
            textComponents: [
                TextComponent(
                    entityId: "lemma-1",
                    textA: "abandon<div>[sound:abandon_400.mp3]</div><div>[\u{0259}'b\u{00E6}nd\u{0259}n]</div>",
                    textB: "n.&nbsp; leave<br />Ex: gave up",
                    language: nil),
                TextComponent(
                    entityId: "lemma-2",
                    textA: "rotate /rou'teit/",
                    textB: nil,
                    language: nil),
            ],
            deckMetas: [],
            edges: [],
            failures: [])
        try world.run(ImportSystem(), context: batch)

        // 直接跑迁移逻辑（等价于 v9）
        try await appDB.dbWriter.write { db in
            try StoredTextSanitizer.stripHeadwordTails(db)
            try StoredTextSanitizer.stripHeadwordTails(db) // 幂等
        }

        let rows = try await appDB.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT entity_id, text_a FROM comp_text ORDER BY entity_id")
        }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0["entity_id"] as String, $0["text_a"] as String?) })
        XCTAssertEqual(byId["lemma-1"], "abandon", "HTML + 方括号音标应全部剥掉")
        XCTAssertEqual(byId["lemma-2"], "rotate", "斜杠音标应剥掉")
    }
}
