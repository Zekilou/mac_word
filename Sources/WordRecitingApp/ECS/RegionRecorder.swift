import Foundation

/// 统一的事件记录入口：所有接入点都走这里。
/// @ai: 事件流是辅助数据——记录失败不得打断主流程（词汇状态已写成功）。
struct RegionRecorder: Sendable {
    let world: World

    /// 仅登记 region（进入页面时调用）。
    func ensure(_ region: RegionRef) {
        try? world.run(RegionSystem(), context: .ensure(region))
    }

    /// 按 lemma id 记录事件，并重算这些词的 BKT 后验。
    func record(lemmaIds: [EntityID], region: RegionRef, kind: WordEventKind,
                trust: Double? = nil, detail: String? = nil) {
        guard !lemmaIds.isEmpty else { return }
        try? world.run(RegionSystem(), context: .record(
            lemmaIds: lemmaIds, region: region, kind: kind, trust: trust, detail: detail))
        try? world.run(MasterySystem(), context: .recompute(lemmaIds: lemmaIds))
    }

    /// 按词面记录事件：解析不到的词静默跳过。
    func record(surfaces: [String], region: RegionRef, kind: WordEventKind,
                trust: Double? = nil, detail: String? = nil) {
        let ids = surfaces.compactMap { try? world.graph.findLemmaId(byTextA: $0) }
        record(lemmaIds: ids, region: region, kind: kind, trust: trust, detail: detail)
    }
}
