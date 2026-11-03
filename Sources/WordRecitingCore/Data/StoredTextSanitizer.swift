import Foundation
import GRDB

/// 存量文本清洗迁移的执行器（v7 / v8）。
/// @ai: 为什么要在 storage 层洗、而不是只在展示层洗——
///      `LemmaFrequencySystem.stamp` 直接拿 `text_a` 去词频表查 band/rank，
///      脏词面（`abandon<div>[sound:…]</div>`）永远查不到 → 词频、CEFR、
///      选词策略（frequencyTier）对这些词全部静默失效。
///      只在 UI 层清洗治标不治本，所以这里把库里的存量数据也洗一遍。
///      清洗口径复用 `TextSanitizer`（与展示层同一套规则），避免两处行为漂移。
enum StoredTextSanitizer {

    /// v7：清 HTML / 媒体标记 / 实体残留（含音标尾巴，但与 v8 幂等叠加）。
    /// 幂等：`TextSanitizer.clean` 只会收紧文本，重复执行结果不变。
    static func run(_ db: Database) throws {
        try cleanColumn(db, table: "comp_text", column: "text_b", preserveLineBreaks: true)
        try cleanColumn(
            db, table: "comp_text", column: "text_a", preserveLineBreaks: false,
            stripHeadwordTail: true)
        // 同义词映射的展示文本来自 comp_edge_span.surface_form（表面形式），
        // 同样可能有媒体标记残留。
        try cleanColumn(
            db, table: "comp_edge_span", column: "surface_form", preserveLineBreaks: false,
            stripHeadwordTail: true)
    }

    /// v8：只剥词面尾巴（`abandon [ə'bændən]` → `abandon`）。
    /// @ai: v7 已去过 HTML，但音标尾巴还在 → 词频表仍匹配不上（实测 402 词只 1 命中）。
    ///      词面是 Lemma 的匹配键，必须只留纯词形。
    static func stripHeadwordTails(_ db: Database) throws {
        try stripColumn(
            db, table: "comp_text", column: "text_a")
        try stripColumn(
            db, table: "comp_edge_span", column: "surface_form")
    }

    // MARK: - 内部

    /// 逐行清洗某一列（清洗 + 可选剥尾巴）：只写真正变化的行。
    private static func cleanColumn(
        _ db: Database, table: String, column: String, preserveLineBreaks: Bool,
        stripHeadwordTail: Bool = false
    ) throws {
        try rewrite(db, table: table, column: column) { raw in
            var value = TextSanitizer.clean(raw, preserveLineBreaks: preserveLineBreaks)
            if stripHeadwordTail, let cleaned = value {
                value = TextSanitizer.cleanHeadword(cleaned)
            }
            return value
        }
    }

    /// 逐行只剥词面尾巴（不再重复 HTML 清洗）。
    private static func stripColumn(
        _ db: Database, table: String, column: String
    ) throws {
        try rewrite(db, table: table, column: column) { raw in
            TextSanitizer.cleanHeadword(raw)
        }
    }

    /// 通用的「读一列 → 变换 → 写回变化行」。
    /// 表名/列名均为编译期字面量（非用户输入），拼接安全。
    private static func rewrite(
        _ db: Database, table: String, column: String,
        transform: (String) -> String?
    ) throws {
        let rows = try Row.fetchAll(
            db, sql: "SELECT entity_id, \(column) AS value FROM \(table)")
        for row in rows {
            let entityId: EntityID = row["entity_id"]
            let raw: String? = row["value"]
            guard let raw, !raw.isEmpty else { continue }
            let cleaned = transform(raw)
            // 清洗后与原文一致 → 无需写回（避免无谓 WAL 增长）。
            guard cleaned != raw else { continue }
            try db.execute(
                sql: "UPDATE \(table) SET \(column) = ? WHERE entity_id = ?",
                arguments: [cleaned, entityId])
        }
    }
}
