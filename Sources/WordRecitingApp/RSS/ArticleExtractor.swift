import Foundation

/// 从文章 HTML 中提取正文文本（简易正文提取，无第三方依赖）。
/// 策略：`<article>` 区段优先 → 回退按 `<p>` 段落拼接 → 回退全页清洗。
/// @ai: 个人学习用途：只提取供阅读，不落库、不缓存全文。
enum ArticleExtractor {

    /// 提取正文纯文本；无有效正文返回空字符串。
    static func extract(from html: String) -> String {
        // 1. <article> 区段优先（多数新闻站的正文容器）
        if let article = section(of: html, tag: "article") {
            let body = paragraphs(of: article)
            if !body.isEmpty { return body }
            // 无 <p> 段落时回退到区段清洗，仍需 ≥ 40 字符才视为有效正文
            let cleaned = article.rssCleanedText()
            if cleaned.count >= 40 { return cleaned }
        }
        // 2. 回退：全页按 <p> 段落拼接
        let body = paragraphs(of: html)
        if !body.isEmpty { return body }
        // 3. 回退：全页清洗（导航噪音较多，仅作兜底；同样需 ≥ 40 字符）
        let cleaned = html.rssCleanedText()
        return cleaned.count >= 40 ? cleaned : ""
    }

    /// 提取首个指定标签的区段文本（不含标签本身）。
    private static func section(of html: String, tag: String) -> String? {
        let lower = html.lowercased()
        guard let open = lower.range(of: "<\(tag)[^>]*>",
                                     options: .regularExpression) else { return nil }
        guard let close = lower.range(of: "</\(tag)>",
                                      options: .regularExpression) else { return nil }
        guard open.upperBound < close.lowerBound else { return nil }
        return String(html[open.upperBound..<close.lowerBound])
    }

    /// 拼接所有 <p> 段落文本（每段换行）；有效正文不足 40 字符视为无正文。
    /// @ai: dotMatchesLineSeparators 支持跨行 <p> 内容。
    private static func paragraphs(of html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<p[^>]*>(.*?)</p>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return "" }
        let ns = html as NSString
        var parts: [String] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let sub = ns.substring(with: match.range(at: 1))
            let cleaned = sub.rssCleanedText()
            if !cleaned.isEmpty { parts.append(cleaned) }
        }
        let joined = parts.joined(separator: "\n")
        return joined.count >= 40 ? joined : ""
    }
}
