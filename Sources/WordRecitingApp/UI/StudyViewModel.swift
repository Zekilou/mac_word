import Foundation
import Observation

/// 背诵 ViewModel：加载到期卡片队列、执行评分、刷新统计。
/// @ai: UI 不写 SQL；评分走 World.run(StudySystem)；查询走 GraphQueries。
@MainActor
@Observable
final class StudyViewModel {

    let world: World
    let settings: AppSettings

    var queue: [CardListItem] = []
    var currentIndex = 0
    var stats: StudyStats?
    var isFront = true
    var errorMessage: String?

    /// 当前卡的 BKT 后验概率（nil = 尚无事件）。
    private(set) var currentBelief: Double?
    /// 当前卡的词频带 / 全表排名。
    private(set) var currentBand: Int?
    private(set) var currentRank: Int?
    /// 当前卡的事件摘要，如 "标记不会 1 次 · 出现过 3 次"。
    private(set) var currentEventSummary: String?

    init(world: World, settings: AppSettings = .shared) {
        self.world = world
        self.settings = settings
    }

    /// 当前卡片。
    var currentCard: CardListItem? {
        guard !queue.isEmpty, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// 队列是否还有卡。
    var hasCards: Bool { currentCard != nil }

    /// 剩余数量。
    var remaining: Int { queue.count - currentIndex }

    /// 刷新队列与统计。
    func reload() {
        do {
            queue = try world.graph.dueCards()
            stats = try world.graph.studyStats()
            currentIndex = 0
            isFront = true
            refreshCurrentProfile()
            errorMessage = nil
        } catch {
            queue = []
            refreshCurrentProfile()
            errorMessage = "\(error)"
        }
    }

    /// 对当前卡片评分，然后进入下一张。
    func rate(_ rating: Rating) {
        guard let card = currentCard else { return }
        do {
            try world.run(StudySystem(), context: StudySystem.StudyOp(
                cardId: card.cardId, rating: rating, reviewedAt: Date()))
            // 主动做题 → 高可信词事件
            RegionRecorder(world: world).record(
                lemmaIds: [card.lemmaId],
                region: .study(cardId: card.cardId),
                kind: rating.rawValue >= Rating.good.rawValue ? .quizCorrect : .quizWrong)
            currentIndex += 1
            isFront = true
            refreshCurrentProfile()
            stats = try world.graph.studyStats()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// 翻转卡片（正面/背面）。
    func flip() {
        isFront.toggle()
    }

    /// 刷新当前卡的模型信息（后验概率 / 词频坐标 / 事件摘要）。
    func refreshCurrentProfile() {
        guard let card = currentCard else {
            currentBelief = nil
            currentBand = nil
            currentRank = nil
            currentEventSummary = nil
            return
        }
        currentBelief = try? world.graph.masteryBelief(lemmaId: card.lemmaId)
        let frequency = try? world.graph.lemmaFrequency(lemmaId: card.lemmaId)
        currentBand = frequency?.band
        currentRank = frequency?.freqRank
        let counts = (try? world.graph.wordEventCountsByKind(lemmaId: card.lemmaId)) ?? [:]
        currentEventSummary = Self.summaryText(counts: counts)
    }

    /// 事件计数 → 摘要文案（纯函数，可单测）。
    nonisolated static func summaryText(counts: [String: Int]) -> String? {
        let order: [WordEventKind] = [
            .quizCorrect, .quizWrong, .markKnown, .markUnknown, .lookup, .seen
        ]
        let parts = order.compactMap { kind -> String? in
            guard let count = counts[kind.rawValue], count > 0 else { return nil }
            return "\(EventTimelinePresenter.kindLabel(kind)) \(count) 次"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
