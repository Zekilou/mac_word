import XCTest
@testable import WordRecitingApp

/// Agentic 逐词融入：类型与管线测试（全部 mock，不跑真实模型）。
final class AgenticEmbeddingTests: XCTestCase {

    func testEmbeddingVerificationLabelsAndAllCases() {
        XCTAssertEqual(EmbeddingVerification.allCases.map(\.rawValue),
                       ["light", "standard", "strict"])
        XCTAssertFalse(EmbeddingVerification.light.label.isEmpty)
    }

    func testGenerationConstraintsDefaultsToStandard() {
        XCTAssertEqual(GenerationConstraints().embeddingVerification, .standard)
    }

    func testGeneratedArticleSkippedWordsDefaultsEmpty() {
        let article = GeneratedArticle(
            body: "x", spans: [], generatorId: "g", tier: .local)
        XCTAssertTrue(article.skippedWords.isEmpty)
    }
}
