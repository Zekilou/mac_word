import Foundation
import Observation
import WordRecitingCore

/// 卡片浏览器 ViewModel：加载某 deck 的卡片列表，支持搜索过滤与详情拉取。
/// @ai: UI 不写 SQL；查询走 GraphQueries 命名方法。
@MainActor
@Observable
final class CardBrowserViewModel {
    let world: World
    let deckId: EntityID
    let deckName: String

    var cards: [CardListItem] = []
    /// 统一筛选状态。
    var filter = ListFilter()
    var selected: CardListItem?
    var detail: LemmaDetail?
    var isLoading = false
    var errorMessage: String?

    init(world: World, deckId: EntityID, deckName: String) {
        self.world = world
        self.deckId = deckId
        self.deckName = deckName
    }

    /// 加载 deck 全部卡片。
    func reload() {
        isLoading = true
        errorMessage = nil
        do {
            cards = try world.graph.cardsInDeck(deckId)
        } catch {
            cards = []
            errorMessage = "\(error)"
        }
        isLoading = false
    }

    /// 当前可见卡片（由 FilterBar 在视图层统一筛选，VM 不再重复实现）。

    /// 选中一张卡片 → 拉取 Lemma 详情。
    func select(_ card: CardListItem) {
        selected = card
        detail = nil
        do {
            detail = try world.graph.lemmaDetail(card.lemmaId)
        } catch {
            detail = nil
            errorMessage = "\(error)"
        }
    }

    /// 删除单张卡片。
    /// @ai: 只删这张卡（学习目标），该词的全局掌握度/词事件保留——
    ///      与删词库同一口径，见 DeckCleanupSystem 注释。
    func deleteCard(_ card: CardListItem) {
        errorMessage = nil
        do {
            try world.run(DeckCleanupSystem(), context: .deleteCard(cardId: card.cardId))
            if selected?.cardId == card.cardId {
                selected = nil
                detail = nil
            }
            reload()
        } catch {
            errorMessage = "删除卡片失败：\(error)"
        }
    }
}
