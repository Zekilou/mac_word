import Foundation
import Observation

/// 背诵 ViewModel：加载到期卡片队列、执行评分、刷新统计。
/// @ai: UI 不写 SQL；评分走 World.run(StudySystem)；查询走 GraphQueries。
@MainActor
@Observable
final class StudyViewModel {

    let world: World

    var queue: [CardListItem] = []
    var currentIndex = 0
    var stats: StudyStats?
    var isFront = true
    var errorMessage: String?

    init(world: World) {
        self.world = world
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
            errorMessage = nil
        } catch {
            queue = []
            errorMessage = "\(error)"
        }
    }

    /// 对当前卡片评分，然后进入下一张。
    func rate(_ rating: Rating) {
        guard let card = currentCard else { return }
        do {
            try world.run(StudySystem(), context: StudySystem.StudyOp(
                cardId: card.cardId, rating: rating, reviewedAt: Date()))
            currentIndex += 1
            isFront = true
            stats = try world.graph.studyStats()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// 翻转卡片（正面/背面）。
    func flip() {
        isFront.toggle()
    }
}
