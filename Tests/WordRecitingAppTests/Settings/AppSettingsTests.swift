import XCTest
import GRDB
@testable import WordRecitingApp

/// AppSettings（UserDefaults 持久化）测试。
/// @ai: 用独立 suite 避免污染 .standard；@MainActor（AppSettings 是 @MainActor）。
final class AppSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    @MainActor func testDefaults() {
        let settings = makeSettings()
        XCTAssertEqual(settings.generatorTier, .remote)
        XCTAssertEqual(settings.remoteProvider, .ollama)
        XCTAssertEqual(settings.llmModel, "qwen2.5")
        XCTAssertEqual(settings.llmBaseURL, "http://localhost:11434/v1")
        XCTAssertNil(settings.localModelPath)
        XCTAssertEqual(settings.schedulerID, .sm2)
    }

    @MainActor func testPersistAndReload() {
        let settings = makeSettings()
        settings.generatorTier = .processLocal
        settings.remoteProvider = .openai
        settings.llmModel = "gpt-4o-mini"
        settings.llmBaseURL = "https://api.openai.com/v1"
        settings.llmAPIKey = "sk-test"
        settings.localModelPath = "/tmp/foo.gguf"
        settings.schedulerID = .fsrsV4

        // 新实例从同一个 defaults 读回
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.generatorTier, .processLocal)
        XCTAssertEqual(reloaded.remoteProvider, .openai)
        XCTAssertEqual(reloaded.llmModel, "gpt-4o-mini")
        XCTAssertEqual(reloaded.llmBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(reloaded.llmAPIKey, "sk-test")
        XCTAssertEqual(reloaded.localModelPath, "/tmp/foo.gguf")
        XCTAssertEqual(reloaded.schedulerID, .fsrsV4)
    }

    @MainActor func testApplyProviderDefaults() {
        let settings = makeSettings()
        settings.remoteProvider = .openai
        settings.applyProviderDefaults()
        XCTAssertEqual(settings.llmBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(settings.llmModel, "gpt-4o-mini")

        settings.llmAPIKey = "sk-x"
        settings.remoteProvider = .ollama
        settings.applyProviderDefaults()
        XCTAssertEqual(settings.llmBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(settings.llmModel, "qwen2.5")
        XCTAssertTrue(settings.llmAPIKey.isEmpty)   // Ollama 不需要 Key，清空
    }

    @MainActor func testResetClearsAll() {
        let settings = makeSettings()
        settings.llmModel = "custom"
        settings.localModelPath = "/tmp/x.gguf"
        settings.reset()
        XCTAssertEqual(settings.llmModel, "qwen2.5")  // 回默认
        XCTAssertNil(settings.localModelPath)
    }

    // MARK: - 逐词融入验证强度

    @MainActor func testEmbeddingVerificationPersists() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.embeddingVerification, .standard, "默认应为 standard")
        settings.embeddingVerification = .strict
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.embeddingVerification, .strict)
    }
}
