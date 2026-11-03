import Foundation

/// AnkiImporter 扩展：HTML 与 Anki 媒体标签清洗。
/// @ai: 拆分文件以控制 AnkiImporter.swift 总行数 ≤300（人机协作工程规范）。
extension AnkiImporter {

    /// 剥掉 Anki 字段里的 HTML 标签、[sound:xxx]、<img...>、HTML 实体、多余空白；
    /// trim 后返回，空字符串返回 nil。
    static func sanitizeHTML(_ raw: String?) -> String? {
        guard var s = raw, !s.isEmpty else { return nil }
        // 正则替换简写
        let re: (String) -> Void = { pattern in
            s = s.replacingOccurrences(
                of: pattern, with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        re("\\[sound:[^\\]]*\\]")
        re("<img\\b[^>]*>")
        re("<[^>]+>")
        // HTML 实体
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'")
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        re("\\s+")
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
