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
            wordState = WordMarkState.from(mastery: mastery, seenCount: seen)
        } catch {
            wordState = .pending
        }
    }

    /// 标记会/不会（极端切换）：已会→不会，否则→会。
    /// @ai: 词元不存在时 batch 自动建 Lemma；不建卡。
    func toggleMark(_ word: String) {
        let known = wordState != .known
        do {
            try world.run(UserKnownSystem(), context:
                .batch(words: [(word, known)], source: "dictionary"))
            refreshState(for: word)
        } catch {
            // 写失败保持原状态，UI 层不崩溃
        }
    }
}
