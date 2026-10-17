import Foundation

/// WordNormalizer：词形归一化工具。
/// 用途：
///  - Lemma 全库唯一 key（归一化词形）：battles / battle / battled → "battle"
///  - 剥离 Anki headword 音标 / 词性尾巴：abandon[ə'bændən] → "abandon"
/// 纯规则后缀剥离，不做词典级屈折还原（WordNet 精确还原属第 2 期）。
/// @ai: 仅纯词形变化归并到同一 Lemma；独立词条（abandon 动词 vs abandoned 形容词）各自独立。
enum WordNormalizer {

    /// 归一化为 Lemma key：清洗 → 小写 → 规则后缀剥离。
    /// 返回空字符串表示无有效词形（调用方应跳过）。
    static func normalize(_ word: String) -> String {
        let cleaned = clean(word)
        guard !cleaned.isEmpty else { return "" }
        // 含空格（短语 / 词组）不剥离后缀，直接返回。
        if cleaned.contains(" ") { return cleaned }
        return stripSuffixes(cleaned.lowercased())
    }

    /// 清洗：剥离 `[音标]` / `/音标/` 尾巴与词性标记；空格后的词性/简短标记只取主词；
    /// 其余保留（词组如 "take up" 原样返回）。
    /// @ai: 音标有两种写法——方括号 `abandon [ə'bændən]`（本库 TOEFL 词库）
    ///      与斜杠 `rotate /rou'teit/`（另一批词库）。两者都不是词形的一部分，
    ///      留着会让词频表查不到、选词清单显示脏词面。
    static func clean(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        // 剥离 [音标] 尾巴（保留空子序列："[音标]" → 首段为 ""）
        let core = trimmed.split(separator: "[", maxSplits: 1,
                                 omittingEmptySubsequences: false)
            .first.map(String.init) ?? trimmed
        let parts = core.split(separator: " ").map(String.init)
        // 空格后为词性/简短标记 → 只取主词部分
        if parts.count > 1, let last = parts.last,
           Self.isPosMark(String(last.lowercased())) {
            return parts.dropLast().joined(separator: " ")
        }
        // 斜杠音标尾巴：`rotate /rou'teit/` → `rotate`
        // 仅当末段是「以 / 开头且以 / 结尾」的音标块时才剥，
        // 避免误伤 `and/or`、`24/7` 这类真实含斜杠的词。
        if parts.count > 1, let last = parts.last, Self.isSlashPhonetic(last) {
            return parts.dropLast().joined(separator: " ")
        }
        return parts.joined(separator: " ")
    }

    /// 是否为斜杠音标块（`/rou'teit/`、`/'soulə/`）：首尾都是 `/`，且内部含重音/音标符号。
    private static func isSlashPhonetic(_ token: String) -> Bool {
        guard token.count > 2,
              token.hasPrefix("/"), token.hasSuffix("/") else { return false }
        let inner = token.dropFirst().dropLast()
        // 音标块通常含重音符号（' 或 ˌ）或非 ASCII 音标字符；
        // 纯 ASCII 字母/数字（如 `and/or`）不算音标，避免误剥。
        return inner.contains("'") || inner.contains("ˌ") || inner.contains("ˈ")
            || inner.contains { !$0.isASCII }
    }

    /// 常见词性 / 简短标记（去符号后比对，如 "(v.)" → "v"）。
    private static func isPosMark(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        return ["v", "n", "adj", "adv", "prep", "conj", "int", "pron",
                "vt", "vi", "a", "ad", "abbr", "phr", "num"].contains(letters)
    }

    // MARK: - 规则后缀剥离（小写输入）

    /// 保守剥离：剩余长度 < 阈值不剥；双写辅音收尾去一个（running → run）。
    /// @ai: 阈值防误伤高频词：-s 需剩 >4（防 this/was/his）、-ed 需剩 >5（防 speed/need）、
    /// -ly 需剩 >6（防 reply/family）；**不做 -er/-est 剥离**（weather/water/paper 误伤率高，
    /// 比较级词形作为独立 lemma 处理，第 2 期 WordNet 精确还原）。
    private static func stripSuffixes(_ lower: String) -> String {
        // ies → y（studies → study，studied → study）
        if lower.count > 4, lower.hasSuffix("ies") {
            return String(lower.dropLast(3)) + "y"
        }
        if lower.count > 4, lower.hasSuffix("ied") {
            return String(lower.dropLast(3)) + "y"
        }
        // es：仅当词干以 s / x / z / ch / sh 结尾（boxes → box, watches → watch, glasses → glass）
        if lower.count > 4, lower.hasSuffix("es") {
            let stem = String(lower.dropLast(2))
            let isEsStem = stem.hasSuffix("s") || stem.hasSuffix("x")
                || stem.hasSuffix("z") || stem.hasSuffix("ch") || stem.hasSuffix("sh")
            if isEsStem { return stem }
        }
        // s → ""（battles → battle, books → book）；防 this(4)/was(3)/his(3)
        // @ai: 长度阈值只看**输入**长度会把 5 字母的 s 结尾单数词砍坏——
        //      旧实现 `class`→`clas`、`process`→`proces`、`glass`→`glas`、`business`→`busines`，
        //      导致单数与复数归一化成两个不同 lemma（`class` vs `classes`）。
        //      额外要求词干不以 s / u / i 结尾：这些是**本身以 s 结尾的单数词**
        //      （class/glass/process/business/address、focus/status/virus/campus、analysis/basis），
        //      不是「加 -s 构成的复数」。
        if lower.count > 4, lower.hasSuffix("s") {
            let stem = String(lower.dropLast(1))
            let singularEnding = stem.hasSuffix("s") || stem.hasSuffix("u") || stem.hasSuffix("i")
            if !singularEnding { return stem }
        }
        // ing → ""（reading → read, running → run）；thing/sing/bring 长度 ≤5 不剥
        if lower.count > 5, lower.hasSuffix("ing") {
            return collapseDouble(String(lower.dropLast(3)))
        }
        // ed → ""（walked → walk, stopped → stop）；防 speed(5)/need(4)/red(3)
        if lower.count > 5, lower.hasSuffix("ed") {
            return collapseDouble(String(lower.dropLast(2)))
        }
        // ly → ""（quickly → quick）；防 reply(5)/family(6)/apply(5)
        if lower.count > 6, lower.hasSuffix("ly") {
            return String(lower.dropLast(2))
        }
        return lower
    }

    /// 双写辅音收尾则去掉一个：runn → run, stopp → stop, bigg → big。
    private static func collapseDouble(_ s: String) -> String {
        guard s.count > 3 else { return s }
        let chars = Array(s)
        if chars[chars.count - 1] == chars[chars.count - 2] {
            return String(chars.dropLast())
        }
        return s
    }
}
