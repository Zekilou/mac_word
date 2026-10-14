import GRDB
import Foundation

/// ImportSystem：在单个写事务内将一个 ImportBatch 落库。
/// 步骤：
///  1. Lemma 去重：按归一化词形复用已有 Lemma（跨词包共享），不存在才新建
///  2. INSERT nodes（deck + 未去重的 lemma + card）
///  3. UPSERT comp_deck_meta / comp_text / comp_schedule_state（lemma 的组件由 LemmaSystem 处理）
///  4. INSERT edges（has / instantiates，指向被去重 lemma 的 dst 替换为实际 id）
///  5. 对每个 failure：INSERT EventNode + comp_import_failure + edge(owns: Deck→Event)
/// requiresAll = []：导入不依赖已有 entity，直接用 context 批量写入。
struct ImportSystem: System {
    static let requiresAll: [ComponentID] = []
    typealias Context = ImportBatch

    func execute(world: World, db: Database, entities: [EntityID], context: ImportBatch) throws {
        let timestamp = context.nodes.first?.createdAt ?? Date()

        // 1. Lemma 去重：归一化词形 → 复用已有 / 批内保留首个原 id，记录 原 id → 实际 id
        //    策略：批内首次出现的词形保留其原始 id 插入（Anki/CSV 稳定 id 语义不变）；
        //    同词形再次出现（跨词包已存在 / 批内变体）复用该 id，仅追加新来源释义。
        let textByEntity = Dictionary(
            context.textComponents.map { ($0.entityId, $0) },
            uniquingKeysWith: { a, _ in a })

        var batchLemmaKey: [String: EntityID] = [:]  // 归一化词形 → 实际 lemma id（批内决议）
        var lemmaIdMap: [EntityID: EntityID] = [:]  // 原 lemma id → 实际 lemma id
        var handledLemmaIDs = Set<EntityID>()        // 复用的 lemma（跳过 node/组件插入）
        // 待追加释义（须在 lemma node 插入后执行以满足 FK）
        var pendingDefinitions: [(lemmaId: EntityID, definition: String, source: String)] = []
        for spec in context.nodes where spec.kind == .lemma {
            guard let tc = textByEntity[spec.id], let raw = tc.textA else { continue }
            let normalized = WordNormalizer.normalize(raw)
            guard !normalized.isEmpty else { continue }
            let source = "deck:\(context.deckId)"
            let def = tc.textB ?? ""

            // 批内已决议 → 复用
            if let actual = batchLemmaKey[normalized] {
                lemmaIdMap[spec.id] = actual
                handledLemmaIDs.insert(spec.id)
                if !def.isEmpty {
                    pendingDefinitions.append((actual, def, source))
                }
                continue
            }
            // 全库已存在 → 复用，不插入
            if let existing = try world.graph.findLemmaId(db, byTextA: normalized) {
                lemmaIdMap[spec.id] = existing
                handledLemmaIDs.insert(spec.id)
                batchLemmaKey[normalized] = existing
                if !def.isEmpty {
                    pendingDefinitions.append((existing, def, source))
                }
                continue
            }
            // 批内首次 → 保留原 id 插入（走下方正常流程），并登记词形决议
            batchLemmaKey[normalized] = spec.id
            if !def.isEmpty {
                pendingDefinitions.append((spec.id, def, source))
            }
        }

        // 2. INSERT nodes（跳过已由 LemmaSystem 处理的 lemma 节点）
        // @ai: 幂等——节点 id 是确定式的（CSV: lemma-<deck>-<词> / card-<deck>-<正面>），
        //      同一文件重复导入、或文件内有重复行时会撞 UNIQUE 约束，
        //      旧实现直接抛错 → **整个导入事务回滚**（用户看到「导入失败」，一条都没进）。
        //      这里改为「已存在则跳过」，并把真正新建的卡片收集起来。
        var insertedNodeIDs = Set<EntityID>()
        for spec in context.nodes {
            if spec.kind == .lemma && handledLemmaIDs.contains(spec.id) { continue }
            try world.registry.insertNodeIfAbsent(
                db, id: spec.id, kind: spec.kind, createdAt: spec.createdAt)
            if db.changesCount > 0 { insertedNodeIDs.insert(spec.id) }
        }

        /// 只有**本次真正新建**的卡片才写初始调度状态。
        /// @ai: 复用已有卡片时若仍 upsert schedule_state，会把用户的复习进度
        ///      （reps / due_at / factor）重置成「新卡」，等于重复导入即清空学习记录。
        let insertedCardIDs = Set(
            context.nodes.filter { $0.kind == .card && insertedNodeIDs.contains($0.id) }
                .map(\.id))

        // 3. UPSERT components（lemma 的 text / lemmaMeta 已由 LemmaSystem 写入）
        for dm in context.deckMetas {
            try world.registry.upsertComponent(db, dm)
        }
        for tc in context.textComponents where !handledLemmaIDs.contains(tc.entityId) {
            try world.registry.upsertComponent(db, tc)
        }
        for lm in context.lemmaMetas where !handledLemmaIDs.contains(lm.entityId) {
            try world.registry.upsertComponent(db, lm)
        }
        for ts in context.tagSets {
            try world.registry.upsertComponent(db, ts)
        }
        for ss in context.scheduleStates where insertedCardIDs.contains(ss.entityId) {
            try world.registry.upsertComponent(db, ss)
        }

        // 4. INSERT edges（被去重 lemma 的 dst 替换为实际 id）
        // @ai: 边同样幂等（插入前先查，已存在则跳过），避免重复导入撞 edges.id 主键。
        for spec in context.edges {
            let dst = lemmaIdMap[spec.dstId] ?? spec.dstId
            try world.registry.insertEdgeIfAbsent(
                db, id: spec.id, srcId: spec.srcId, dstId: dst,
                rel: spec.rel, createdAt: spec.createdAt)
        }

        // 4.5 追加多来源释义（此时所有 lemma node 已存在，满足 FK）
        for p in pendingDefinitions {
            try LemmaSystem.appendDefinition(
                world: world, db: db, lemmaId: p.lemmaId,
                definition: p.definition, source: p.source)
        }

        // 5. failures → EventNode + comp_import_failure + owns edge
        // @ai: 同样幂等——failure 的 entityId 含行号（确定式），重复导入会撞主键。
        for f in context.failures {
            try world.registry.insertNodeIfAbsent(
                db, id: f.entityId, kind: .event, createdAt: timestamp)
            try world.registry.upsertComponent(db, ImportFailureComponent(
                entityId: f.entityId, deckId: f.deckId, rowIndex: f.rowIndex,
                rawLine: f.rawLine, reason: f.reason))
            try world.registry.insertEdgeIfAbsent(
                db, id: "owns-\(f.entityId)", srcId: f.deckId, dstId: f.entityId,
                rel: .owns, createdAt: timestamp)
        }
    }
}
