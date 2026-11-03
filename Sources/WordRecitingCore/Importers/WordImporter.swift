import Foundation

/// 词库导入器协议：识别文件 → 读出 ImportBatch。
/// 实现方负责把任意格式（CSV / Anki .apkg / 纯文本）解析为统一的 ImportBatch，
/// 不直接写库——落库由 ImportSystem 在单事务内完成。
/// @ai: 新增 Importer 只需实现本协议，不修改 ImportSystem。
public protocol WordImporter: Sendable {
    /// 导入器唯一标识（如 "csv" / "anki"）。
    static var identifier: String { get }
    /// 支持的文件扩展名（小写，不含点）。
    static var supportedExtensions: [String] { get }
    /// 是否能导入该 URL（默认按扩展名匹配，可覆盖做内容嗅探）。
    func canImport(url: URL) -> Bool
    /// 读取并解析为 ImportBatch。progress 在 0...1 区间回调进度。
    func readNodes(from url: URL, progress: @escaping (Double) -> Void) async throws -> ImportBatch
}

/// 一次导入批次的数据载体（Importer 输出 → ImportSystem 输入）。
/// 描述要落库的 nodes / 组件 / edges / failures，由 ImportSystem 在单事务内写入。
/// @ai: 兼容 Anki / 纯文本词库的统一中间表示。
public struct ImportBatch: Sendable {
    public struct NodeSpec: Sendable {
        public let id: EntityID
        public let kind: NodeKind
        public let createdAt: Date
    }

    public struct EdgeSpec: Sendable {
        public let id: EntityID
        public let srcId: EntityID
        public let dstId: EntityID
        public let rel: EdgeRel
        public let createdAt: Date
    }

    public struct FailureSpec: Sendable {
        public let entityId: EntityID
        public let deckId: EntityID
        public let rowIndex: Int
        public let rawLine: String
        public let reason: String
    }

    /// 主 deck id（导入目标，用于批次标识；failures 各自带 deckId）。
    public let deckId: EntityID
    /// 所有待插入节点（deck + lemma/card 等）。
    public let nodes: [NodeSpec]
    /// 待 upsert 的文本组件（通常对应 card / lemma）。
    public let textComponents: [TextComponent]
    /// 待 upsert 的 deck 元数据（支持多 deck）。
    public let deckMetas: [DeckMetaComponent]
    /// 待 upsert 的 lemma 元数据（pos / phonetic / senses）。
    public let lemmaMetas: [LemmaMetaComponent]
    /// 待 upsert 的标签集合组件。
    public let tagSets: [TagSetComponent]
    /// 待 upsert 的调度状态组件。
    public let scheduleStates: [ScheduleStateComponent]
    /// 待插入的边（has / instantiates 等）。
    public let edges: [EdgeSpec]
    /// 导入失败记录，每条生成 EventNode + comp_import_failure + owns 边。
    public let failures: [FailureSpec]

    public init(
        deckId: EntityID,
        nodes: [NodeSpec],
        textComponents: [TextComponent],
        deckMetas: [DeckMetaComponent],
        lemmaMetas: [LemmaMetaComponent] = [],
        tagSets: [TagSetComponent] = [],
        scheduleStates: [ScheduleStateComponent] = [],
        edges: [EdgeSpec],
        failures: [FailureSpec]
    ) {
        self.deckId = deckId
        self.nodes = nodes
        self.textComponents = textComponents
        self.deckMetas = deckMetas
        self.lemmaMetas = lemmaMetas
        self.tagSets = tagSets
        self.scheduleStates = scheduleStates
        self.edges = edges
        self.failures = failures
    }
}
