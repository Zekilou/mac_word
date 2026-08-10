import Foundation

/// 词库导入器协议：识别文件 → 读出 ImportBatch。
/// 实现方负责把任意格式（CSV / Anki .apkg / 纯文本）解析为统一的 ImportBatch，
/// 不直接写库——落库由 ImportSystem 在单事务内完成。
/// @ai: 新增 Importer 只需实现本协议，不修改 ImportSystem。
protocol WordImporter: Sendable {
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
struct ImportBatch: Sendable {
    struct NodeSpec: Sendable {
        let id: EntityID
        let kind: NodeKind
        let createdAt: Date
    }

    struct EdgeSpec: Sendable {
        let id: EntityID
        let srcId: EntityID
        let dstId: EntityID
        let rel: EdgeRel
        let createdAt: Date
    }

    struct FailureSpec: Sendable {
        let entityId: EntityID
        let deckId: EntityID
        let rowIndex: Int
        let rawLine: String
        let reason: String
    }

    /// 主 deck id（导入目标，用于批次标识；failures 各自带 deckId）。
    let deckId: EntityID
    /// 所有待插入节点（deck + lemma/card 等）。
    let nodes: [NodeSpec]
    /// 待 upsert 的文本组件（通常对应 card / lemma）。
    let textComponents: [TextComponent]
    /// 待 upsert 的 deck 元数据（支持多 deck）。
    let deckMetas: [DeckMetaComponent]
    /// 待 upsert 的 lemma 元数据（pos / phonetic / senses）。
    let lemmaMetas: [LemmaMetaComponent]
    /// 待 upsert 的标签集合组件。
    let tagSets: [TagSetComponent]
    /// 待 upsert 的调度状态组件。
    let scheduleStates: [ScheduleStateComponent]
    /// 待插入的边（has / instantiates 等）。
    let edges: [EdgeSpec]
    /// 导入失败记录，每条生成 EventNode + comp_import_failure + owns 边。
    let failures: [FailureSpec]

    init(
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
