import GRDB
import Foundation

/// UserKnownSystem：用户词汇掌握度（全局上下文，挂 Lemma，高于任何词包）。
/// 状态与卡片彻底分离——只记"会不会"（mastery），不建卡。
/// **mastery 值域（unsigned float）**：0 = 无记录（未标记）；1 = 完全不会；2 = 完全会；1~2 连续渐变。
/// requiresAll = []：初始化 / 文章词反馈时词元可能不存在，需要先 findOrCreate。
/// @ai: 词包的卡片复习进度是局部上下文（comp_schedule_state），本表是全局上下文。
struct UserKnownSystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = UserKnownOp

    /// 值域常量。
    static let masteryNone: Double = 0      // 无记录
    static let masteryUnknown: Double = 1   // 完全不会
    static let masteryKnown: Double = 2     // 完全会

    func execute(world: World, db: Database, entities: [EntityID], context: UserKnownOp) throws {
        switch context {
        case .markKnown(let lemmaId, let source, let mastery):
            try upsert(world: world, db: db, lemmaId: lemmaId,
                       mastery: mastery, source: source)
        case .markUnknown(let lemmaId, let source):
            try upsert(world: world, db: db, lemmaId: lemmaId,
                       mastery: Self.masteryUnknown, source: source)
        case .adjust(let lemmaId, let delta, let source):
            let existing: UserKnownComponent? = try world.registry.fetchComponents(
                db, for: lemmaId, table: "comp_user_known")
            // 无记录（nil 或 0）视为从"不会"起步
            let current = max(existing?.mastery ?? Self.masteryUnknown, Self.masteryUnknown)
            try upsert(world: world, db: db, lemmaId: lemmaId,
                       mastery: min(Self.masteryKnown, max(Self.masteryUnknown, current + delta)),
                       source: source)
        case .batch(let words, let source):
            for item in words {
                // 词元不存在时自动创建 Lemma（全局词追踪不限于词库内单词）
                guard let lemmaId = try LemmaSystem.findOrCreateLemma(
                    world: world, db: db,
                    input: LemmaInput(textA: item.word, source: source,
                                      createdAt: Date()))
                else { continue }
                try upsert(world: world, db: db, lemmaId: lemmaId,
                           mastery: item.known ? Self.masteryKnown : Self.masteryUnknown,
                           source: source)
            }
        case .markSeen(let words, let source):
            for word in words {
                guard let lemmaId = try LemmaSystem.findOrCreateLemma(
                    world: world, db: db,
                    input: LemmaInput(textA: word, source: source, createdAt: Date()))
                else { continue }
                try recordSeen(world: world, db: db, lemmaId: lemmaId, source: source)
            }
        }
    }

    /// 普通状态写入：保留现有 seenCount，覆盖 mastery。
    private func upsert(
        world: World, db: Database, lemmaId: EntityID, mastery: Double, source: String
    ) throws {
        guard try world.registry.fetchNode(db, id: lemmaId) != nil else {
            throw UserKnownError.lemmaNotFound(lemmaId)
        }
        let existing: UserKnownComponent? = try world.registry.fetchComponents(
            db, for: lemmaId, table: "comp_user_known")
        try world.registry.upsertComponent(db, UserKnownComponent(
            entityId: lemmaId, mastery: mastery,
            seenCount: existing?.seenCount ?? 0,
            source: source, updatedAt: Date()))
    }

    /// 记录"出现过"：mastery 不变（无记录保持 0，不判定会/不会），seenCount + 1。
    private func recordSeen(
        world: World, db: Database, lemmaId: EntityID, source: String
    ) throws {
        let existing: UserKnownComponent? = try world.registry.fetchComponents(
            db, for: lemmaId, table: "comp_user_known")
        try world.registry.upsertComponent(db, UserKnownComponent(
            entityId: lemmaId,
            mastery: existing?.mastery ?? Self.masteryNone,
            seenCount: (existing?.seenCount ?? 0) + 1,
            source: source, updatedAt: Date()))
    }
}

// MARK: - 操作枚举

enum UserKnownOp: Sendable {
    /// 标记会：mastery = 2（source: init / article / manual）。
    case markKnown(lemmaId: EntityID, source: String, mastery: Double = 2.0)
    /// 标记不会：mastery = 1。
    case markUnknown(lemmaId: EntityID, source: String)
    /// 微调掌握度：clamp 1...2（无记录从 1 起步）。
    case adjust(lemmaId: EntityID, delta: Double, source: String)
    /// 批量标记：词形 → 是否会。词元不存在时自动创建 Lemma。
    case batch(words: [(word: String, known: Bool)], source: String)
    /// 批量记录"出现过"：mastery 不变（无记录保持 0），seenCount + 1。RSS 文章阅读时调用。
    case markSeen(words: [String], source: String)
}

enum UserKnownError: Error, Sendable, Equatable {
    case lemmaNotFound(EntityID)
}
