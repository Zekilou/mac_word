import Foundation

/// 通用文本清洗：Anki 富文本（HTML 标签 / [sound:...] 媒体标记 / 实体）→ 可读纯文本。
/// @ai: 词面（text_a）与释义（text_b）展示前统一清洗；导入侧（AnkiImporter+Sanitize）
///      清洗后的新数据干净，本工具为**旧数据兜底** + 统一口径（所有 GraphQueries 输出处调用）。
enum TextSanitizer {

    /// 清洗为可读文本。
    /// - Parameter preserveLineBreaks: true = 释义（保留 <br>/<div> 换行，例句分行可读）；
    ///   false = 词面（全部折叠为单行，便于匹配/显示）。
    static func clean(_ raw: String?, preserveLineBreaks: Bool) -> String? {
        guard var s = raw, !s.isEmpty else { return nil }
        // 1) Anki 媒体标记 [sound:xxx.mp3]
        s = s.replacingOccurrences(
            of: "\\[sound:[^\\]]*\\]", with: "",
            options: [.regularExpression, .caseInsensitive])
        // 2) 换行标签 → 换行（仅释义模式；词面不需要）
        if preserveLineBreaks {
            s = s.replacingOccurrences(
                of: "<br\\s*/?>", with: "\n",
                options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(
                of: "</?(div|p)\\s*/?>", with: "\n",
                options: [.regularExpression, .caseInsensitive])
        }
        // 3) 其余 HTML 标签 → 空格（防内联标签剥除后单词粘连，如 up<i>x</i> → up x）
        s = s.replacingOccurrences(
            of: "<[^>]+>", with: " ",
            options: [.regularExpression, .caseInsensitive])
        // 4) HTML 实体
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"),
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // 5) 空白折叠：行内多空白 → 单空格；释义模式保留换行结构并去空行
        if preserveLineBreaks {
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            s = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        } else {
            s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        // 6) 标点前多余空格（标签转空格导致 "foo : bar" / "foo , bar"）
        s = s.replacingOccurrences(
            of: "\\s+([:,.!?;])", with: "$1",
            options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 词面专用清洗：HTML/媒体标记清洗 → 再剥掉音标 / 词性尾巴。
    /// `abandon<div>[sound:…]</div><div>[ə'bændən]</div>` → `abandon`
    /// @ai: 词面（text_a）是 **Lemma 的匹配键**，必须只留纯词形：
    ///      - 词频表按纯词形查 band/rank（`abandon [ə'bændən]` 查不到）
    ///      - 选词清单 / 卡片正面只该显示单词本身
    ///      音标另有归属（comp_lemma_meta.phonetic_*），不该混在词面里。
    ///      清洗后为空则回退到「仅去 HTML」的结果，避免把整行洗没。
    static func cleanHeadword(_ raw: String?) -> String? {
        guard let cleaned = clean(raw, preserveLineBreaks: false) else { return nil }
        let stripped = WordNormalizer.clean(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? cleaned : stripped
    }
}
