import Darwin
import Foundation

/// 词典条目（清洗后的单词语义：词性/音标/释义全文）。
struct DictionaryEntry: Equatable, Sendable {
    let word: String
    /// 音标（IPA，如 "əˈbandən"）；未识别为 nil。
    let phonetic: String?
    /// 词性（noun / verb / adjective …）；未识别为 nil。
    let partOfSpeech: String?
    /// 清洗后的释义全文（音标/词性后的完整内容，含例句）。
    let definition: String
}

/// macOS 系统词典查询服务（Dictionary Services）。
/// 通过私有 API `DCSCopyTextDefinition` 按词查询本机已启用词典（牛津英英等）。
/// @ai: ① 私有 API 经 dlsym 调用（未在 Swift 头声明）；② 只能按词查询、无枚举能力
///      → 交互是"懒加载"（搜索即查，不预导入），当作本地远端数据库；③ DCS 调用放后台线程。
final class SystemDictionaryService: @unchecked Sendable {
    static let shared = SystemDictionaryService()

    private typealias LookupFn = @convention(c) (CFTypeRef?, CFString, CFRange)
        -> Unmanaged<CFString>?

    private let lookupFn: LookupFn?

    init() {
        if let handle = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_NOW | RTLD_GLOBAL),
            let sym = dlsym(handle, "DCSCopyTextDefinition") {
            lookupFn = unsafeBitCast(sym, to: LookupFn.self)
        } else {
            lookupFn = nil
        }
    }

    /// 系统词典服务是否可用（符号存在即可）。
    func isAvailable() -> Bool { lookupFn != nil }

    /// 查询一个词的词典条目（懒加载：只查指定词，返回 nil 表示词典中无此词/服务不可用）。
    func lookup(_ word: String) async -> DictionaryEntry? {
        guard let lookupFn else { return nil }
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let html = await Task.detached(priority: .userInitiated) { () -> String? in
            let w = trimmed as CFString
            guard let result = lookupFn(nil, w,
                                        CFRange(location: 0, length: CFStringGetLength(w))) else {
                return nil
            }
            return result.takeRetainedValue() as String
        }.value
        guard let html, !html.isEmpty else { return nil }
        return Self.parseEntry(word: trimmed, html: html)
    }

    // MARK: - 清洗（纯函数，可测试）

    /// 把 DCS 返回的 HTML 清洗成可读条目（剥标签/实体/折叠空白 + 提取音标与词性）。
    static func parseEntry(word: String, html: String) -> DictionaryEntry? {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities {
            text = text.replacingOccurrences(of: k, with: v)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 音标：| IPA |（仅收含 IPA 专用字符的段，防误吞普通 | 分隔内容）
        var phonetic: String?
        if let m = text.range(of: "\\|[^|]+\\|", options: .regularExpression) {
            let inner = text[m].dropFirst().dropLast()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ipaChars: [Character] = ["ˈ", "ˌ", "ə", "ɜ", "ʊ", "ɪ", "ʃ", "ʒ", "θ", "ð", "ŋ",
                                         "æ", "ɒ", "ɔ", "ʌ", "ː", "ɛ", "ɚ", "ɝ", "ɑ", "ɾ"]
            if inner.contains(where: { ipaChars.contains($0) }) {
                phonetic = String(inner)
            }
        }

        // 词性（首个出现的词性词）
        var partOfSpeech: String?
        let posPattern = "\\b(noun|verb|adjective|adverb|preposition|pronoun|conjunction|"
            + "interjection|determiner|exclamation|abbreviation|auxiliary verb)\\b"
        if let m = text.range(of: posPattern, options: .regularExpression) {
            partOfSpeech = String(text[m])
        }

        return DictionaryEntry(word: word, phonetic: phonetic,
                               partOfSpeech: partOfSpeech, definition: text)
    }
}
