import XCTest
@testable import WordRecitingApp

/// 生成输出 token 动态化 + 上下文压缩测试：
/// bodyMaxTokens 随目标字数联动（不再硬编码 600）；ContextCompressor 超窗 head-tail 截断。
final class ContextCompressorTests: XCTestCase {

    private struct MockClient: LLMClient {
        static let identifier = "mock"
        let response: String
        func complete(prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
            response
        }
    }

    private func makeGen(contextWindow: Int = 2048, outputTokenLimit: Int? = nil) -> LocalLLMGenerator {
        LocalLLMGenerator(
            client: MockClient(response: ""),
            contextWindow: contextWindow, outputTokenLimit: outputTokenLimit)
    }

    // MARK: - 动态输出上限（字数联动，不硬编码）

    func testBodyMaxTokensScalesWithWords() {
        let gen = makeGen()
        XCTAssertEqual(gen.bodyMaxTokens(maxWords: 100), 350, "100 词 → 100×1.5+200")
        XCTAssertEqual(gen.bodyMaxTokens(maxWords: 300), 650, "300 词 → 450+200")
        XCTAssertEqual(gen.bodyMaxTokens(maxWords: 2000), 1536,
                       "2000 词→3200，但 clamp 到窗口 3/4=1536")
    }

    func testBodyMaxTokensRespectsFixedLimitAndWindow() {
        XCTAssertEqual(makeGen(outputTokenLimit: 800).bodyMaxTokens(maxWords: 300), 800,
                       "用户固定上限优先")
        XCTAssertEqual(makeGen(contextWindow: 1024).bodyMaxTokens(maxWords: 1000), 768,
                       "cap = 1024×3/4 = 768")
        XCTAssertEqual(makeGen(outputTokenLimit: 9999).bodyMaxTokens(maxWords: 300), 1536,
                       "固定上限也 clamp 到窗口 3/4")
    }

    // MARK: - ContextCompressor

    func testEstimateTokensApprox() {
        XCTAssertTrue(ContextCompressor.estimateTokens("hello world") >= 1)
        let long = String(repeating: "word ", count: 300)
        XCTAssertGreaterThanOrEqual(ContextCompressor.estimateTokens(long), 200,
                                    "300 词长文本估算应显著大于 0")
    }

    func testTruncateKeepsShortText() {
        let s = "Short text."
        XCTAssertEqual(ContextCompressor.truncate(s, toBudget: 1000), s, "未超窗原样返回")
        XCTAssertEqual(ContextCompressor.truncate(s, toBudget: 0), s, "预算≤0 不压缩")
    }

    func testTruncateTrimsMiddleForLongText() {
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)
        let truncated = ContextCompressor.truncate(long, toBudget: 50)
        XCTAssertNotEqual(truncated, long, "超预算应压缩")
        XCTAssertTrue(truncated.contains("..."), "包含省略标记")
        XCTAssertTrue(truncated.hasPrefix("The quick"), "保留头部（指令/规则）")
        XCTAssertTrue(truncated.hasSuffix("lazy dog. "), "保留尾部（正文/文章）")
    }

    func testCompressContextOnlyWhenOverWindow() {
        let gen = makeGen()
        let short = "Write a short article about tea."
        XCTAssertEqual(gen.compressContext(short, reservedForOutput: 300), short,
                       "未超窗原样返回")
        // budget = 2048 − 300 − 256 = 1492 tokens；4500 词长 prompt 远超 → 压缩
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 500)
        let out = gen.compressContext(long, reservedForOutput: 300)
        XCTAssertNotEqual(out, long)
        XCTAssertTrue(out.contains("..."), "超窗应 head-tail 压缩")
    }

    /// 强制规则区常驻：超窗压缩只截规则块之后的内容（词列表/计划/文章），规则永不丢失。
    /// @ai: 回归用例——旧 head-tail 截断会把 prompt 中部的"禁止释义"指令切掉，正文又写释义。
    func testCompressContextProtectsHardRules() {
        let gen = makeGen()
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 500)
        let prompt = LocalLLMGenerator.hardRules + "\n\n" + long
        let out = gen.compressContext(
            prompt, reservedForOutput: 300, protectedPrefix: LocalLLMGenerator.hardRules)

        XCTAssertTrue(out.hasPrefix(LocalLLMGenerator.hardRules), "规则区常驻完整保留")
        XCTAssertTrue(out.contains("STRICTLY FORBIDDEN"), "禁止释义规则未被压缩掉")
        XCTAssertTrue(out.contains("explains a target word"), "关键约束措辞保留")
        XCTAssertNotEqual(out, prompt, "规则区之后的内容被压缩")
        XCTAssertTrue(out.contains("..."), "含省略标记")
    }

    /// hardRules 前置：正文/草稿 prompt 以规则块开头（压缩保护的前提）；
    /// 自查（polishPrompt）用**独立干净上下文**（reviewInstructions，不重复 hardRules）——上下文隔离。
    func testHardRulesAtPromptStart() {
        let gp = LocalLLMGenerator.generatePrompt(theme: "科技", words: ["abandon"], maxWords: 100)
        XCTAssertTrue(gp.hasPrefix(LocalLLMGenerator.hardRules), "generatePrompt 规则前置")
        let plain = GenStrategyPrompt.plainPrompt(theme: "", maxWords: 100)
        XCTAssertTrue(plain.hasPrefix(LocalLLMGenerator.hardRules), "plainPrompt 规则前置")

        // 自查：独立干净指令，不携带 hardRules（防小模型回显规则文本/被上下文带偏）
        let pp = LocalLLMGenerator.polishPrompt(article: "x")
        XCTAssertTrue(pp.hasPrefix(LocalLLMGenerator.reviewInstructions),
                      "polishPrompt 以干净自查指令开头")
        XCTAssertFalse(pp.hasPrefix(LocalLLMGenerator.hardRules),
                       "自查不以生成侧 hardRules 开头（上下文隔离）；"
                       + "reviewInstructions 中引用该短语仅为待删示例，语义上是干净上下文")
    }

    /// 明显异常兜底：释义开头/规则回显/音标音频混入 → isNoArticle 拦截（即使 ≥100 字符）。
    func testIsNoArticleCatchesObviousAbnormalities() {
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "The word \"augment\" is used to describe adding or increasing something."),
            "释义开头应拦")
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "The term \"haunting\" is a word that expresses the idea of something being memorable."),
            "释义开头应拦")
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "The rules of the game are always in effect, no exceptions. [hɔ:nt] (haunt_400.mp3)"),
            "规则回显 + 音标/音频混入应拦")
        // 单词表形态 + 哨兵尾巴（真实落库坏记录 article-83AB1521 形态）：词表行 + 结尾 NO_ARTICLE
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "Affection\n- Deep affection or love for someone.\n- Often expressed through words like \"loving,\" \"hate.\"\n\nAlleyway\n\nAgnosticism\n- A philosophical stance denying the existence of a supreme being such as God.\n\n---\n\nNO_ARTICLE"),
            "词表 + NO_ARTICLE 哨兵行应拦")
        // 纯词表形态（"词\n- 释义"，无哨兵、无正常句子）也应拦
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "battle\n- a fight between two groups\nplague\n- a disease that spreads across a region"),
            "纯词表形态应拦")
        // 正常文章（即使以 The word 开头但非释义句式）不误伤
        XCTAssertFalse(LocalLLMGenerator.isNoArticle(
            "The word echoes across the valley as the battle begins. We must never abandon our hopes."))
        // 正常文章带少量列表行（有独立正常句子）不误伤
        XCTAssertFalse(LocalLLMGenerator.isNoArticle(
            "We should never abandon our dreams. The battle continues every day.\n- The war took a toll on the city.\n- People kept fighting for hope."),
            "正常文章含少量列表行不应误判为词表")
        // 2b) 思考通道标记泄漏（真实落库坏记录 article-658C2324 开头形态）
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "<|channel|>thought\nLet me think about the topic before writing."),
            "DeepSeek 思考通道标记泄漏应拦")
        // 2c) 上下文压缩占位符被复述（真实落库形态：Affection 正文 [..] / 658C2324 中文省略说明）
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "Affection is a deep connection that grows over time.\n[...]\n\nHowever, it can evolve."),
            "[...] 压缩占位符复述应拦")
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "The text covers several themes. 上下文过长，中间已省略，剩余内容如下。"),
            "中文压缩省略说明复述应拦")
        // 3) 哨兵拼写错误变体（真实落库形态：<channel|>NO_ARTRICLE）
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "This article seems fine and complete.\n<channel|>NO_ARTRICLE"),
            "哨兵拼写变体行应拦")
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "<channel|>NO_ARTRICLE"),
            "整篇哨兵拼写变体应拦")
        // 5) 释义式开头（真实落库形态：Affection / Haunting 词典条目句式）
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "Affection is a deep and lasting emotional connection that can evolve over time."),
            "普通大写名词 + is a ... that 释义式开头应拦")
        XCTAssertTrue(LocalLLMGenerator.isNoArticle(
            "Haunting is a phenomenon that has captivated the imagination of many readers. "
                + "It refers to an atmosphere of unease."),
            "Haunting 释义式开头应拦")
        // 不误伤：正常文章开头/含 channel 单词/普通含 is a 的句子
        XCTAssertFalse(LocalLLMGenerator.isNoArticle(
            "Technology has transformed human life at a pace that would have stunned our grandparents."),
            "正常文章开头不应误判")
        XCTAssertFalse(LocalLLMGenerator.isNoArticle(
            "Morning routine includes waking up, preparing for the day, and getting through the day."),
            "Morning routine 开头不应误判")
        XCTAssertFalse(LocalLLMGenerator.isNoArticle(
            "The broadcast channel reached a wide audience across the region."),
            "含 channel 单词但无管道符不应误判")
        XCTAssertFalse(LocalLLMGenerator.isNoArticle(
            "A garden is a quiet place where people can relax and read."),
            "A 开头（停用词）不应误判为释义")
    }
}
