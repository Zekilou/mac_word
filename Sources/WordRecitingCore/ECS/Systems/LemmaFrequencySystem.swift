import Foundation
import GRDB

/// LemmaFrequencySystem：把词频族坐标落到 Lemma 上。
/// @ai: 表外词不写组件（保持「无坐标」语义）；重复打标幂等覆盖。
struct LemmaFrequencySystem: System {
    /// 只处理带 text 组件的实体，内部再按 kind == .lemma 过滤。
    static let requiresAll: [ComponentID] = [.text]
    typealias Context = LemmaFrequencyOp

    let provider: any WordFrequencyProvider

    func execute(world: World, db: Database, entities: [EntityID], context: LemmaFrequencyOp) throws {
        switch context {
        case .stamp(let lemmaId):
            try stamp(world: world, db: db, lemmaId: lemmaId)

        case .stampAll:
            for entityId in entities {
                guard try world.registry.fetchNode(db, id: entityId)?.kind == .lemma else { continue }
                try stamp(world: world, db: db, lemmaId: entityId)
            }
        }
    }

    private func stamp(world: World, db: Database, lemmaId: EntityID) throws {
        let text: TextComponent? = try world.registry.fetchComponents(
            db, for: lemmaId, table: "comp_text")
        guard let word = text?.textA?.trimmingCharacters(in: .whitespacesAndNewlines),
              !word.isEmpty else { return }
        guard let band = provider.band(for: word) else { return }
        try world.registry.upsertComponent(db, LemmaFrequencyComponent(
            entityId: lemmaId,
            band: band,
            freqRank: provider.rank(for: word) ?? 0,
            source: provider.sourceName))
    }
}

/// LemmaFrequencySystem 的上下文操作。
enum LemmaFrequencyOp: Sendable {
    /// 单个词元增量打标。
    case stamp(lemmaId: EntityID)
    /// 全量回填（幂等）。
    case stampAll
}
