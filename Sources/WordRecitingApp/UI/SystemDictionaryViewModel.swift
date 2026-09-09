import Foundation
import Observation

/// 系统词典查询 ViewModel：搜索词 → 懒加载查系统词典 → 展示条目 + 标记会不会。
/// @ai: 标记走 UserKnownSystem（写全局掌握度不建卡），与初始化/RSS 同口径。
@MainActor
@Observable
final class SystemDictionaryViewModel {

    enum Phase: Equatable {
        case idle
        case looking
        case found(DictionaryEntry)
        case notFound(String)
    }

    var phase: Phase = .idle
    var wordState: WordMarkState = .pending
    var lastQuery = ""
    /// 词画像：BKT 后验概率（nil = 尚无事件）。
    var belief: Double?
    /// 词频带 / 全表排名。
    var frequencyBand: Int?
    var frequencyRank: Int?
    /// 最近 5 条词事件（时间倒序）。
    var recentEvents: [EventTimelineItem] = []

    let world: World
    let service: SystemDictionaryService
    private let clientOverride: DictionaryLookup?

    /// 可注入的查询闭包（测试用；nil = 真实系统词典服务）。
    typealias DictionaryLookup = @Sendable (String) async -> DictionaryEntry?

    init(world: World,
         service: SystemDictionaryService = .shared,
         lookupOverride: DictionaryLookup? = nil) {
        self.world = world
        self.service = service
        self.clientOverride = lookupOverride
    }

    /// 查询一个词（懒加载）：更新状态 + 刷新该词的全局掌握度。
    func search(_ word: String) async {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }
        lastQuery = trimmed
        phase = .looking
        if let lookup = clientOverride {
            if let entry = await lookup(trimmed) {
                await applyFound(entry)
            } else {
                phase = .notFound(trimmed)
            }
            return
        }
        if !service.isAvailable() {
            phase = .notFound(trimmed)
            return
        }
        if let entry = await service.lookup(trimmed) {
            await applyFound(entry)
        } else {
            phase = .notFound(trimmed)
        }
    }

    private func applyFound(_ entry: DictionaryEntry) async {
        phase = .found(entry)
        refreshState(for: entry.word)
    }

    /// 刷新指定词的全局掌握度状态（会话标记后也调用）。
    func refreshState(for word: String) {
        do {
            let lemmaID = try world.graph.findLemmaId(byTextA: word)
            let mastery: Double? = lemmaID.flatMap { id in
                (try? world.graph.lemmaMastery(lemmaId: id)) ?? nil
            }
            let seenCounts = (try? world.graph.allLemmaSeenCounts()) ?? [:]
            let seen: Int = lemmaID.flatMap { seenCounts[$0] } ?? 0
            belief = lemmaID.flatMap { try? world.graph.masteryBelief(lemmaId: $0) } ?? nil
            wordState = WordMarkState.from(belief: belief, mastery: mastery, seenCount: seen)
            loadProfile(lemmaID: lemmaID)
        } catch {
            wordState = .pending
            clearProfile()
        }
    }

    /// 词画像：词频坐标 + 最近事件。
    private func loadProfile(lemmaID: EntityID?) {
        guard let lemmaID else {
            clearProfile()
            return
        }
        let frequency = try? world.graph.lemmaFrequency(lemmaId: lemmaID)
        frequencyBand = frequency?.band
        frequencyRank = frequency?.freqRank

        let rows = (try? world.graph.wordEvents(lemmaId: lemmaID, limit: 5)) ?? []
        let regionIDs = Array(Set(rows.map(\.regionId)))
        let kinds = (try? world.graph.regionKinds(regionIds: regionIDs)) ?? [:]
        recentEvents = EventTimelinePresenter.items(from: rows, regionKinds: kinds)
    }

    private func clearProfile() {
        belief = nil
        frequencyBand = nil
        frequencyRank = nil
        recentEvents = []
    }

    /// 标记会/不会（极端切换）：已会→不会，否则→会。
    /// @ai: 方向由**显式标记**（comp_user_known）决定，而非概率状态——按钮写的是显式掌握度；
    ///      概率只负责展示判定，不能反过来决定按钮写什么。
    func toggleMark(_ word: String) {
        let lemmaID = try? world.graph.findLemmaId(byTextA: word)
        let explicitMastery: Double? = lemmaID.flatMap { id in
            (try? world.graph.lemmaMastery(lemmaId: id)) ?? nil
        }
        let known = (explicitMastery ?? 0) < 1.999
        do {
            try world.run(UserKnownSystem(), context:
                .batch(words: [(word, known)], source: "dictionary"))
            RegionRecorder(world: world).record(
                surfaces: [word], region: .dictionary(),
                kind: known ? .markKnown : .markUnknown, trust: 1.0)
            refreshState(for: word)
        } catch {
            // 写失败保持原状态，UI 层不崩溃
        }
    }
}
