import Foundation

/// RSS / Atom 源中的一篇文章条目。
struct RSSItem: Identifiable, Sendable, Equatable {
    /// guid 优先，回退 link。
    let id: String
    let title: String
    let link: String
    /// 摘要正文（RSS description / Atom summary，含 HTML 时由调用方清洗）。
    let summary: String
    /// 全文正文（RSS content:encoded / Atom content，可为空——很多源只有摘要）。
    let content: String
    let pubDate: Date?
}

/// RSS 2.0 / Atom XML 解析器（XMLParser，无第三方依赖）。
/// @ai: 只解析不抓取；正文用 summary（RSS 通常只有摘要，全文抓取属后续迭代）。
enum RSSParser {

    static func parse(data: Data) throws -> [RSSItem] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw RSSParseError.invalidXML(
                parser.parserError?.localizedDescription ?? "unknown")
        }
        return delegate.items
    }
}

enum RSSParseError: Error, Sendable, Equatable {
    case invalidXML(String)
    case invalidURL(String)
}

// MARK: - Delegate

private final class ParserDelegate: NSObject, XMLParserDelegate {

    var items: [RSSItem] = []

    private var path: [String] = []
    private var inItem = false
    private var isAtom = false
    private var title = ""
    private var link = ""
    private var summary = ""
    private var content = ""
    private var guid = ""
    private var dateStr = ""
    private var buffer = ""

    // MARK: Start element

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        path.append(elementName)
        let parent = path.dropLast().last
        switch elementName {
        case "feed":
            isAtom = true
        case "item", "entry":
            inItem = true
            title = ""; link = ""; summary = ""; content = ""; guid = ""; dateStr = ""
        case "link":
            // Atom 的 link 是属性 href；RSS 的 link 是文本
            if let href = attributeDict["href"] {
                link = href
            }
        default:
            break
        }
        // 记录父标签（用于 item 内的子元素判断）
        if inItem, parent == "item" || parent == "entry" {
            buffer = ""
        }
        _ = elementName
    }

    // MARK: Characters

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        buffer += string
    }

    // MARK: End element

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer { path.removeLast() }
        guard inItem else {
            if elementName == "feed" { isAtom = false }
            return
        }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": title = text
        case "link": if link.isEmpty { link = text }
        case "description", "summary": summary = text
        // RSS content 模块全文（content:encoded）；Atom 的 content 元素也在 isAtom 时认作全文
        case "content:encoded", "encoded": content = text
        case "content" where isAtom: content = text
        case "guid", "id": guid = text
        case "pubDate", "updated", "published", "date": dateStr = text
        case "item", "entry":
            inItem = false
            appendItem()
        default:
            break
        }
        if inItem { buffer = "" }
    }

    private func appendItem() {
        let id = guid.isEmpty ? link : guid
        guard !id.isEmpty, !title.isEmpty else { return }
        items.append(RSSItem(
            id: id, title: title, link: link,
            summary: summary, content: content, pubDate: Self.parseDate(dateStr)))
    }

    // MARK: - 日期解析（RFC 822 / ISO8601）

    private static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let d = rfc822.date(from: trimmed) { return d }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }
}

/// RSS 文章正文清洗：去掉 HTML 标签与常见实体，折叠空白。
extension String {
    /// 简易 HTML → 纯文本（剥离标签与实体）。
    func rssCleanedText() -> String {
        var s = self
        // 剥离 <script>...</script> 与 <style>...</style> 块
        let blockTags = ["script", "style"]
        for tag in blockTags {
            while let range = s.range(of: "<\(tag)[^>]*>.*?</\(tag)>",
                                      options: [.regularExpression, .caseInsensitive]) {
                s.replaceSubrange(range, with: " ")
            }
        }
        // 换行/段落标签 → 换行
        s = s.replacingOccurrences(
            of: "</p>|<br\\s*/?>|</div>|</li>|</h[1-6]>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        // 其余标签删除
        s = s.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        // HTML 实体
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        // 折叠空白
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
