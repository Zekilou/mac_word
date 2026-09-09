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
    /// 一次「显示词汇的上下文」（页面/会话级）。
    case region
    /// 每日统计快照节点（趋势数据源，载荷存 comp_analytics_cache）。
    case analyticsDay = "analytics_day"
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
    /// 词汇显示上下文（挂 Region 节点）。
    case region
    /// 单次词事件（全量事件流，挂 Event 节点）。
    case wordEvent = "word_event"
    /// 词频族坐标（挂 Lemma 节点）。
    case lemmaFrequency = "lemma_frequency"
    /// BKT 后验掌握度概率（挂 Lemma）。
    case masteryBelief = "mastery_belief"
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
    /// SM-2 + 词频/概率调制。
    case sm2Frequency = "sm-2-frequency"
}

/// 选词打分策略。
enum WordScoringID: String, Sendable, Codable, CaseIterable {
    /// 纯随机（复刻旧行为）。
    case random
    /// 临界词优先：概率 0.5 附近最该练。
    case criticalWords = "critical-words"
    /// 词频分层：按词频带优先。
    case frequencyTier = "frequency-tier"
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

/// 生成质量档位（设计文档 §4.1 定义三档）。
/// - fast   → RuleBasedGenerator（模式 B 同义词替换，默认快速档）
/// - local  → LocalLLMGenerator / AgentSidecarGenerator（Apple Silicon 本地推理）
/// - remote → RemoteAPIGenerator（阶段三可选接入，当前无实现消费，预留档）
/// @ai: 契约枚举，勿改 rawValue / case 顺序。
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
    var help: String {
        switch self {
        case .light: return "逐词融入后只查词在不在，不调 LLM 验证语义（少调用，适合本地慢速小模型）"
        case .standard: return "首次验证语义保真（多一次小调用），后续按存在性规则检查"
        case .strict: return "每个词融入后都调 LLM 验证语义，最稳但调用最多（适合云端 API / 大模型）"
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

// MARK: - LlamaServerLifecycle（本地 agent 增强进程生命周期）

/// llama-server 进程生命周期策略（仅 useLocalAgentEnhancement 启用时生效）。
/// @ai: 进程内本地档（.processLocal）启用「本地 agent 增强」后，spawn llama-server
///      监听 localhost:port 供 sidecar 调用；此枚举决定 spawn/stop 时机。
enum LlamaServerLifecycle: String, Sendable, Codable, CaseIterable, Identifiable {
    /// 常驻：App 启动时 spawn，App 退出时 stop。生成零启动延迟，模型常驻内存。
    case persistent = "persistent"
    /// 按生成启停：每次生成 spawn，生成完成 stop。启动延迟约 1-3s，内存按需释放。
    case perGenerate = "perGenerate"
    /// 闲置超时停：首次生成 spawn，闲置 N 分钟自动 stop，再次生成重新 spawn。平衡启动延迟与内存。
    case idleTimeout = "idleTimeout"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .persistent: return "常驻（启动即加载，零延迟）"
        case .perGenerate: return "按生成启停（省内存，启动延迟）"
        case .idleTimeout: return "闲置超时停（平衡）"
        }
    }

    /// 闲置超时秒数（仅 .idleTimeout 生效）。
    static let idleTimeoutSeconds: TimeInterval = 300
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

// MARK: - RegionKind（词汇显示上下文种类）

/// 词汇显示上下文的种类（region 的业务分类）。
enum RegionKind: String, Sendable, Codable, CaseIterable {
    /// 复习卡片：用户主动做题。
    case study
    /// RSS 文章：被动阅读。
    case rss
    /// 生成文章：被动阅读。
    case generate
    /// 词典查词：用户主动查询。
    case dictionary
    /// 词汇初始化会话：用户主动标记。
    case initSession = "init"
    /// v6 迁移合成的事件所属上下文（旧数据回填，便于识别/回滚）。
    case legacy
}

// MARK: - WordEventKind（单次词事件种类）

/// 单次词事件的种类（有限枚举，全量记录）。
enum WordEventKind: String, Sendable, Codable, CaseIterable {
    /// 在文章中被动出现。
    case seen
    /// 用户主动查词。
    case lookup
    /// 用户标记「会」。
    case markKnown = "mark_known"
    /// 用户标记「不会」。
    case markUnknown = "mark_unknown"
    /// 做题答对。
    case quizCorrect = "quiz_correct"
    /// 做题答错。
    case quizWrong = "quiz_wrong"
}
