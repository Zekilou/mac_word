// @ai: AI 合同文件 — 集中所有枚举与值类型。
// 不得改 case 顺序、不得改 rawValue、不得删除 case。
// 新增 case 只能追加到末尾。
import Foundation

// MARK: - EntityID

typealias EntityID = String

// MARK: - NodeKind

enum NodeKind: String, Sendable, Codable, CaseIterable {
    case lemma
    case card
    case deck
    case sentence
    case article
    case event
    case edge
}

// MARK: - EdgeRel
// 有向边的语义标签，对应 spec §3.3 的 12 种关系。

enum EdgeRel: String, Sendable, Codable, CaseIterable {
    case has
    case instantiates
    case hasState = "has_state"
    case produces
    case appearsIn = "appears_in"
    case translatesTo = "translates_to"
    case aggregatesTo = "aggregates_to"
    case contains
    case highlightedIn = "highlighted_in"
    case mapsTo = "maps_to"
    case owns
    case hasMedia = "has_media"
}

// MARK: - ComponentID
// 每个 comp_* 组件表的标识，case 名 = 表名去 comp_ 前缀。

enum ComponentID: String, Sendable, Codable, CaseIterable {
    case text
    case lemmaMeta = "lemma_meta"
    case deckMeta = "deck_meta"
    case scheduleState = "schedule_state"
    case reviewEvent = "review_event"
    case mediaRefs = "media_refs"
    case generationMeta = "generation_meta"
    case edgeSpan = "edge_span"
    case edgeWeighted = "edge_weighted"
    case edgePosition = "edge_position"
    case tagSet = "tag_set"
    case order
    case customData = "custom_data"
    case importFailure = "import_failure"
    case analyticsCache = "analytics_cache"
    /// 用户词汇掌握度（全局上下文，挂 Lemma）。
    case userKnown = "user_known"
    /// 多来源释义（挂 Lemma）。
    case lemmaDefinition = "lemma_definition"
}

// MARK: - Rating

enum Rating: Int, Sendable, Codable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

// MARK: - SchedulerID

enum SchedulerID: String, Sendable, Codable, CaseIterable {
    case fsrsV4 = "fsrs-v4"
    case sm2 = "sm-2"
}

// MARK: - DeckSourceKind

enum DeckSourceKind: String, Sendable, Codable, CaseIterable {
    case anki
    case csv
    case manual
}

// MARK: - GenerationMode

enum GenerationMode: String, Sendable, Codable, CaseIterable {
    case generate
    case rewrite
}

// MARK: - QualityTier

enum QualityTier: String, Sendable, Codable, CaseIterable {
    case fast
    case local
    case remote
}

// MARK: - EmbeddingVerification（逐词融入验证强度）

/// 逐词融入的验证强度：按模型大小 / token 速率 / 云端 API 选择。
/// @ai: 轻量=本地慢速小模型；标准=通用；严格=云端 API / 大模型。
enum EmbeddingVerification: String, CaseIterable, Identifiable, Codable, Sendable {
    case light, standard, strict
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "轻量（本地小模型）"
        case .standard: return "标准（推荐）"
        case .strict: return "严格（云端/大模型）"
        }
    }
}

// MARK: - GenerationConstraints

struct GenerationConstraints: Sendable, Codable {
    var maxWords: Int = 300
    var language: String = "auto"
    var preserveTone: Bool = true
    var synonymDistance: Double = 0.4
    /// 逐词融入验证强度（generate-rewrite 路径）。nil=默认 standard。
    var embeddingVerification: EmbeddingVerification = .standard
    /// 造文模式的用户主题（如 "科技趋势"、"环保"）。改写模式忽略。
    var topic: String?
}

// MARK: - GeneratorTier（生成方式）

/// 生成器档位：进程内本地（swift-llama-cpp）/ 远端 LLM（Ollama 或 OpenAI API）。
/// @ai: 纯规则档已按用户要求移除；Ollama 属于远端。
enum GeneratorTier: String, Sendable, Codable, CaseIterable, Identifiable {
    case processLocal = "进程内本地"
    case remote = "远端 LLM"
    var id: String { rawValue }
}

// MARK: - RemoteProvider（远端服务类型）

/// 远端 LLM 服务：Ollama（本机 / 局域网）或 OpenAI API（云端）。
enum RemoteProvider: String, Sendable, Codable, CaseIterable, Identifiable {
    case ollama = "Ollama"
    case openai = "OpenAI API"
    var id: String { rawValue }

    var defaultModel: String {
        switch self {
        case .ollama: return "qwen2.5"
        case .openai: return "gpt-4o-mini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434/v1"
        case .openai: return "https://api.openai.com/v1"
        }
    }

    /// OpenAI API 需要 API Key；Ollama 本地可留空。
    var needsAPIKey: Bool {
        switch self {
        case .ollama: return false
        case .openai: return true
        }
    }

    var hint: String {
        switch self {
        case .ollama: return "本机已装 Ollama：先 `ollama serve` 并 `ollama pull <模型名>`"
        case .openai: return "云端 API：需要有效 API Key（联网，默认关闭）"
        }
    }
}
