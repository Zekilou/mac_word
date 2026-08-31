import Foundation
import Observation

/// 卡片浏览器 ViewModel：加载某 deck 的卡片列表，支持搜索过滤与详情拉取。
/// @ai: UI 不写 SQL；查询走 GraphQueries 命名方法。
@MainActor
@Observable
final class CardBrowserViewModel {
    let world: World
    let deckId: EntityID
    let deckName: String

    var cards: [CardListItem] = []
    var searchText: String = ""
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

    /// 当前可见卡片（应用搜索过滤）。
    var visibleCards: [CardListItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return cards }
        return cards.filter {
            $0.plainText.lowercased().contains(q)
                || ($0.definition?.lowercased().contains(q) ?? false)
        }
    }

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
}
