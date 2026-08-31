import GRDB
import Foundation

/// LemmaSystem：确保词元存在（findOrCreate），多来源释义合并追加。
/// 用途：
///  - 全局词追踪初始化 / 文章词反馈：词形 → Lemma（全库唯一，key = 归一化词形）
///  - 导入去重：ImportSystem 复用 findOrCreateLemma，跨词包共享 Lemma
/// requiresAll = []：创建新节点，不依赖 entity 签名过滤。
/// @ai: 状态与卡片彻底分离——本 System 只保证词元存在，不建卡。
struct LemmaSystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = LemmaOp

    func execute(world: World, db: Database, entities: [EntityID], context: LemmaOp) throws {
        switch context {
        case .ensure(let input):
            _ = try Self.findOrCreateLemma(world: world, db: db, input: input)
        }
    }

    // MARK: - 共享 findOrCreate（LemmaSystem / UserKnownSystem / ImportSystem 复用）

    /// 按归一化词形查找 Lemma；不存在则新建（id = "lemma:<归一化词形>"）。
    /// 已存在的 Lemma：主释义不覆盖，仅把新来源释义追加到 comp_lemma_definitions。
    static func findOrCreateLemma(
        world: World, db: Database, input: LemmaInput
    ) throws -> EntityID? {
        let normalized = WordNormalizer.normalize(input.textA)
        guard !normalized.isEmpty else { return nil }

        // 已存在 → 复用；追加新来源释义（去重，不覆盖）
        if let existing = try world.graph.findLemmaId(db, byTextA: normalized) {
            if let def = input.definition, !def.isEmpty {
                try appendDefinition(world: world, db: db, lemmaId: existing,
                                     definition: def, source: input.source)
            }
            return existing
        }

        // 不存在 → 新建 Lemma
        let id = "lemma:" + normalized
        try world.registry.insertNode(db, id: id, kind: .lemma, createdAt: input.createdAt)
        try world.registry.upsertComponent(db, TextComponent(
            entityId: id, textA: normalized, textB: input.textB, language: "en"))
        if input.pos != nil || input.phonetic != nil || input.sensesJson != nil {
            try world.registry.upsertComponent(db, LemmaMetaComponent(
                entityId: id, pos: input.pos, phoneticUs: input.phonetic,
                phoneticUk: nil, sensesJson: input.sensesJson))
        }
        if let def = input.definition, !def.isEmpty {
            try appendDefinition(world: world, db: db, lemmaId: id,
                                 definition: def, source: input.source)
        }
        return id
    }

    // MARK: - 多来源释义合并

    /// 追加释义到 comp_lemma_definitions（按 source + definition 去重）。
    /// internal：ImportSystem 去重时对复用的 Lemma 追加新来源释义。
    static func appendDefinition(
        world: World, db: Database, lemmaId: EntityID,
        definition: String, source: String
    ) throws {
        let existing: LemmaDefinitionComponent? = try world.registry.fetchComponents(
            db, for: lemmaId, table: "comp_lemma_definitions")
        var entries = existing
            .flatMap { $0.definitionsJson }
            .flatMap { try? JSONDecoder().decode([DefinitionEntry].self, from: Data($0.utf8)) }
            ?? []
        if entries.contains(where: { $0.source == source && $0.definition == definition }) {
            return
        }
        entries.append(DefinitionEntry(source: source, definition: definition))
        let data = try JSONEncoder().encode(entries)
        try world.registry.upsertComponent(db, LemmaDefinitionComponent(
            entityId: lemmaId,
            definitionsJson: String(data: data, encoding: .utf8)))
    }
}

// MARK: - 输入 / 上下文 / 数据结构

/// Lemma 创建输入。definition 单独传入，追加进多来源释义合并表。
struct LemmaInput: Sendable {
    let textA: String
    let textB: String?
    let pos: String?
    let phonetic: String?
    let sensesJson: String?
    /// 释义来源标识："deck:<deckId>" / "init" / "manual"。
    let source: String
    let definition: String?
    let createdAt: Date

    init(
        textA: String, textB: String? = nil, pos: String? = nil,
        phonetic: String? = nil, sensesJson: String? = nil,
        source: String, definition: String? = nil, createdAt: Date = Date()
    ) {
        self.textA = textA
        self.textB = textB
        self.pos = pos
        self.phonetic = phonetic
        self.sensesJson = sensesJson
        self.source = source
        self.definition = definition
        self.createdAt = createdAt
    }
}

/// 多来源释义条目（comp_lemma_definitions.definitions_json 的元素）。
struct DefinitionEntry: Codable, Sendable, Equatable {
    let source: String
    let definition: String
}

/// LemmaSystem 的操作枚举。
enum LemmaOp: Sendable {
    case ensure(LemmaInput)
}
