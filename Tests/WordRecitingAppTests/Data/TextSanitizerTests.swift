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
}
