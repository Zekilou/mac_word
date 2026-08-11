import Foundation

/// 正则断句：按 . ! ? 句末标点切分；保护常见缩写与引号内句号。
/// @ai: 纯规则实现，不引 spaCy；文章为模型生成，句式规范，本工具只做保守切分。
enum SentenceSplitter {

    /// 常见缩写（句号不作为断句点）。
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
        "e.g", "i.e", "a.m", "p.m", "u.s", "u.k", "ph.d", "no", "fig", "vol",
    ]

    /// 把文本切成句子数组（保留原文句子标点，首尾去空白）。
    static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var sentences: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if isEndPunct(c) {
                let nextIsBreak = (i + 1 >= chars.count) || chars[i + 1].isWhitespace
                    || isClosingPunct(chars[i + 1])
                if nextIsBreak && !endsWithAbbreviation(current) && !insideUnclosedQuote(current) {
                    // 吞掉紧随的闭合引号/右括号（归属当前句）
                    var j = i + 1
                    while j < chars.count && isClosingPunct(chars[j]) {
                        current.append(chars[j])
                        j += 1
                    }
                    let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { sentences.append(s) }
                    current = ""
                    i = j
                    continue
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    private static func isEndPunct(_ c: Character) -> Bool {
        c == "." || c == "!" || c == "?" || c == "。" || c == "！" || c == "？"
    }

    private static func isClosingPunct(_ c: Character) -> Bool {
        c == "\"" || c == "”" || c == "'" || c == ")" || c == "]"
    }

    /// 当前句以「缩写 + 句号」结尾（如 "Dr." / "e.g."），不切分。
    private static func endsWithAbbreviation(_ current: String) -> Bool {
        guard current.hasSuffix(".") else { return false }
        let body = String(current.dropLast())
        let word = body.split(separator: " ").last.map(String.init) ?? body
        let lower = word.lowercased()
        // 大写单字母（如 "T. S. Eliot" 的 T.）视为缩写
        if lower.count == 1, lower.allSatisfy(\.isLetter) { return true }
        return abbreviations.contains(lower)
    }

    /// 当前句内左引号数 > 右引号数 → 在引号内，句号不切分。
    private static func insideUnclosedQuote(_ current: String) -> Bool {
        let open = current.filter { $0 == "\"" || $0 == "“" }.count
        let close = current.filter { $0 == "\"" || $0 == "”" }.count
        return open > close
    }
}
