import SwiftUI
import WordRecitingCore

/// 卡片浏览器：Deck 内所有卡片（词+释义+复习状态），左侧列表 + 右侧详情。
/// 详情展示释义、词性、已定义同义词、该词出现过的文章。
/// @ai: 查询走 CardBrowserViewModel → GraphQueries；UI 不写 SQL。
struct CardBrowserView: View {
    let world: World
    let deckId: EntityID
    let deckName: String
    @State private var vm: CardBrowserViewModel?
    /// 待删除的卡片（非 nil 时弹二次确认）。
    @State private var pendingCardDeletion: CardListItem?

    var body: some View {
        Group {
            if let vm {
                content(vm)
            } else {
                ProgressView().onAppear {
                    let m = CardBrowserViewModel(world: world, deckId: deckId, deckName: deckName)
                    vm = m
                    m.reload()
                }
            }
        }
        .confirmationDialog(
            pendingCardDeletion.map { "删除卡片「\($0.plainText)」？" } ?? "",
            isPresented: Binding(
                get: { pendingCardDeletion != nil },
                set: { if !$0 { pendingCardDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let card = pendingCardDeletion { vm?.deleteCard(card) }
                pendingCardDeletion = nil
            }
            Button("取消", role: .cancel) { pendingCardDeletion = nil }
        } message: {
            Text("只从该词库移除这张卡片。你对这个词的「会 / 不会」标记与复习记录会保留。")
        }
    }

    private func content(_ vm: CardBrowserViewModel) -> some View {
        // @ai: 禁用 HSplitView（macOS 27 beta 拖分栏会触发 FocusBridge key-view-loop 崩溃，
        //      见 docs/superpowers/specs/2026-08-11-ui-redesign-design.md「禁用 List 与 HSplitView 拖拽」）。
        //      改用固定左栏 + Divider + 弹性右栏，与 ReadingView 同款两栏布局。
        HStack(spacing: 0) {
            listPane(vm).frame(width: Size.sidebarWide)
            Rule()
            detailPane(vm).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(deckName)
    }

    // MARK: - 左：卡片列表

    private func listPane(_ vm: CardBrowserViewModel) -> some View {
        // @ai: 统一筛选条。卡片浏览支持掌握度 / 词频带 / 概率 / 到期 / 次数筛选
        //      （旧实现只有一个搜索框）。
        //      `.band` 现在可用——`CardListItem` 就是 `WordCore.Card`，
        //      词频坐标随 `wordCoreColumnsByCard` 一起返回（此前它缺这个字段，
        //      卡片页的「按词频筛」根本启用不了）。
        WordListPane(
            items: vm.cards,
            filter: Binding(get: { vm.filter }, set: { vm.filter = $0 }),
            facets: [.text, .definition, .mark, .band, .belief, .due, .seen, .sort],
            searchPlaceholder: "搜索单词或释义",
            emptyIcon: "rectangle.stack.badge.questionmark",
            emptyTitle: "该词库暂无卡片"
        ) { card in
            cardRow(vm, card: card)
        }
    }

    private func cardRow(_ vm: CardBrowserViewModel, card: CardListItem) -> some View {
        Button {
            vm.select(card)
        } label: {
            HStack(alignment: .top, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(card.plainText)
                        .font(Type.section)
                        .foregroundStyle(vm.selected?.cardId == card.cardId ? .primary : .primary)
                    if let def = card.definition, !def.isEmpty {
                        Text(def)
                            .font(Type.caption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                // 全局掌握度徽标（与词汇 Tab 同口径 WordMarkState.from；无记录不显示避免噪音）
                masteryBadge(card)
                if card.reps != nil {
                    Text("\(card.reps ?? 0)次")
                        .font(Type.micro)
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.vertical, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(vm.selected?.cardId == card.cardId
                    ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }

    /// 掌握度胶囊：概率优先（无概率回退显式标记）；无记录不显示，避免全库灰点噪音。
    @ViewBuilder
    private func masteryBadge(_ card: CardListItem) -> some View {
        let state = WordMarkState.from(
            belief: card.belief, mastery: card.mastery, seenCount: card.seenCount)
        if state != .pending {
            Text(state.label)
                .font(Type.micro)
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xxs)
                .background(state.color.opacity(0.18))
                .foregroundStyle(state.color)
                .clipShape(Capsule())
                .help(badgeHelp(card, state: state))
        }
    }

    private func badgeHelp(_ card: CardListItem, state: WordMarkState) -> String {
        if let belief = card.belief {
            return "\(MasteryPresentation.helpText(belief))；当前档位：\(state.label)"
        }
        return "全局掌握度（用户显式标记）：\(state.label)"
    }

    // MARK: - 右：详情

    @ViewBuilder
    private func detailPane(_ vm: CardBrowserViewModel) -> some View {
        if let detail = vm.detail {
            detailView(vm, detail: detail)
        } else if let card = vm.selected {
            VStack {
                Spacer()
                Text(card.plainText).font(.title).foregroundStyle(Ink.secondary)
                Spacer()
            }
        } else {
            VStack {
                Spacer()
                Text("← 选择左侧一张卡片查看详情").foregroundStyle(Ink.tertiary)
                Spacer()
            }
        }
    }

    private func detailView(_ vm: CardBrowserViewModel, detail: LemmaDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                // 词面
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(detail.text).font(.title).fontWeight(.semibold)
                    if let pos = detail.pos, !pos.isEmpty {
                        Text(pos).font(Type.caption).foregroundStyle(Ink.secondary)
                            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if let card = vm.selected, card.lemmaId == detail.lemmaId {
                        masteryBadge(card)
                    }
                    Spacer()
                    // 删除这张卡片（保留该词的全局掌握度）
                    if let card = vm.selected, card.lemmaId == detail.lemmaId {
                        Button(role: .destructive) {
                            pendingCardDeletion = card
                        } label: {
                            Label("删除卡片", systemImage: "trash")
                                .font(Type.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("从词库移除这张卡片（该词的掌握度与学习记录保留）")
                    }
                }
                if let def = detail.definition, !def.isEmpty {
                    Text(def).font(Type.body).foregroundStyle(.primary)
                }
                Rule()

                // 同义词（词多时折叠，避免标签墙撑爆详情区）
                Text("同义词").font(Type.section)
                if detail.synonyms.isEmpty {
                    Text("暂无同义词映射")
                        .font(Type.caption).foregroundStyle(Ink.tertiary)
                } else {
                    let labels = detail.synonyms.map { $0.surfaceForm ?? "(无表面形式)" }
                    ChipWall(words: labels, maxVisible: 15, minWidth: 90) { label in
                        PlainChip(word: label)
                    }
                }
                Rule()

                // 出现过的文章
                Text("出现过的文章").font(Type.section)
                if detail.articles.isEmpty {
                    Text("该词尚未出现在生成文章中")
                        .font(Type.caption).foregroundStyle(Ink.tertiary)
                } else {
                    ForEach(detail.articles, id: \.articleId) { hit in
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(hit.preview)
                                .font(Type.caption)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                            Text(hit.createdAt, style: .date)
                                .font(Type.micro).foregroundStyle(Ink.tertiary)
                        }
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.page)
        }
    }
}


