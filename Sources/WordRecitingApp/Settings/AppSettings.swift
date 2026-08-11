import Foundation
import Observation

/// 应用设置（UserDefaults 持久化）。
/// 集中管理：LLM 生成配置（档位 / 远端服务 / 模型路径）+ 复习调度算法。
/// @ai: 设置页与生成页共用；UI 通过 SettingsViewModel 读写，不改裸 defaults。
@MainActor
@Observable
final class AppSettings {

    /// 全局共享实例（App 生命周期内单例）。
    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 键名

    private enum Key {
        static let generatorTier = "settings.generatorTier"
        static let remoteProvider = "settings.remoteProvider"
        static let llmModel = "settings.llmModel"
        static let llmBaseURL = "settings.llmBaseURL"
        static let llmAPIKey = "settings.llmAPIKey"
        static let localModelPath = "settings.localModelPath"
        static let schedulerID = "settings.schedulerID"
        static let embeddingVerification = "settings.embeddingVerification"
    }

    // MARK: - 生成配置

    /// 默认生成方式（进程内本地 / 远端 LLM）。默认远端，进程内引擎接入后用户可在设置切换。
    var generatorTier: GeneratorTier {
        get {
            guard let raw = defaults.string(forKey: Key.generatorTier),
                  let tier = GeneratorTier(rawValue: raw) else { return .remote }
            return tier
        }
        set { defaults.set(newValue.rawValue, forKey: Key.generatorTier) }
    }

    /// 远端服务类型（Ollama / OpenAI API）。
    var remoteProvider: RemoteProvider {
        get {
            guard let raw = defaults.string(forKey: Key.remoteProvider),
                  let provider = RemoteProvider(rawValue: raw) else { return .ollama }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Key.remoteProvider) }
    }

    var llmModel: String {
        get { defaults.string(forKey: Key.llmModel) ?? RemoteProvider.ollama.defaultModel }
        set { defaults.set(newValue, forKey: Key.llmModel) }
    }

    var llmBaseURL: String {
        get { defaults.string(forKey: Key.llmBaseURL) ?? RemoteProvider.ollama.defaultBaseURL }
        set { defaults.set(newValue, forKey: Key.llmBaseURL) }
    }

    var llmAPIKey: String {
        get { defaults.string(forKey: Key.llmAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Key.llmAPIKey) }
    }

    // MARK: - 进程内模型

    /// 当前选中的进程内 GGUF 模型文件路径。
    var localModelPath: String? {
        get { defaults.string(forKey: Key.localModelPath) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.localModelPath)
            } else {
                defaults.removeObject(forKey: Key.localModelPath)
            }
        }
    }

    // MARK: - 复习调度

    /// 复习调度算法（当前 StudySystem 固定 SM-2；FSRS 接入后生效）。
    var schedulerID: SchedulerID {
        get {
            guard let raw = defaults.string(forKey: Key.schedulerID),
                  let sid = SchedulerID(rawValue: raw) else { return .sm2 }
            return sid
        }
        set { defaults.set(newValue.rawValue, forKey: Key.schedulerID) }
    }

    // MARK: - 逐词融入验证强度

    /// generate-rewrite 逐词融入的验证强度（light/standard/strict）。
    var embeddingVerification: EmbeddingVerification {
        get {
            guard let raw = defaults.string(forKey: Key.embeddingVerification),
                  let level = EmbeddingVerification(rawValue: raw) else { return .standard }
            return level
        }
        set { defaults.set(newValue.rawValue, forKey: Key.embeddingVerification) }
    }

    // MARK: - 工具

    /// 应用远端服务切换的默认值（地址/模型/Key 状态）。
    func applyProviderDefaults() {
        llmBaseURL = remoteProvider.defaultBaseURL
        llmModel = remoteProvider.defaultModel
        if !remoteProvider.needsAPIKey {
            llmAPIKey = ""
        }
    }

    /// 清除全部设置（测试用）。
    func reset() {
        for key in [Key.generatorTier, Key.remoteProvider, Key.llmModel,
                    Key.llmBaseURL, Key.llmAPIKey, Key.localModelPath,
                    Key.schedulerID, Key.embeddingVerification] {
            defaults.removeObject(forKey: key)
        }
    }
}
