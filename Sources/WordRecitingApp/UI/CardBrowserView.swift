import SwiftUI

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
            listPane(vm).frame(width: 300)
            Divider()
            detailPane(vm).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(deckName)
    }

    // MARK: - 左：卡片列表

    private func listPane(_ vm: CardBrowserViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索单词或释义", text: Binding(
                    get: { vm.searchText },
                    set: { vm.searchText = $0 }
                ))
                .textFieldStyle(.plain)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).padding(8)
            }
            if vm.cards.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.questionmark")
                        .font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("该词库暂无卡片").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // @ai: 不用 List（NSTableView），避免 macOS 27 FocusBridge 拖分栏/布局时 key view loop 崩溃
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.visibleCards) { card in
                            cardRow(vm, card: card)
                        }
                    }
                }
            }
        }
    }

    private func cardRow(_ vm: CardBrowserViewModel, card: CardListItem) -> some View {
        Button {
            vm.select(card)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.plainText)
                        .font(.headline)
                        .foregroundStyle(vm.selected?.cardId == card.cardId ? .primary : .primary)
                    if let def = card.definition, !def.isEmpty {
                        Text(def)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                // 全局掌握度徽标（与词汇 Tab 同口径 WordMarkState.from；无记录不显示避免噪音）
                masteryBadge(card)
                if card.reps != nil {
                    Text("\(card.reps ?? 0)次")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
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
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
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
                Text(card.plainText).font(.title).foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            VStack {
                Spacer()
                Text("← 选择左侧一张卡片查看详情").foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private func detailView(_ vm: CardBrowserViewModel, detail: LemmaDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 词面
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(detail.text).font(.title).fontWeight(.semibold)
                    if let pos = detail.pos, !pos.isEmpty {
                        Text(pos).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
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
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("从词库移除这张卡片（该词的掌握度与学习记录保留）")
                    }
                }
                if let def = detail.definition, !def.isEmpty {
                    Text(def).font(.body).foregroundStyle(.primary)
                }
                Divider()

                // 同义词（词多时折叠，避免标签墙撑爆详情区）
                Text("同义词").font(.headline)
                if detail.synonyms.isEmpty {
                    Text("暂无同义词映射")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    let labels = detail.synonyms.map { $0.surfaceForm ?? "(无表面形式)" }
                    ChipWall(words: labels, maxVisible: 15, minWidth: 90) { label in
                        PlainChip(word: label)
                    }
                }
                Divider()

                // 出现过的文章
                Text("出现过的文章").font(.headline)
                if detail.articles.isEmpty {
                    Text("该词尚未出现在生成文章中")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(detail.articles, id: \.articleId) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.preview)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                            Text(hit.createdAt, style: .date)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}


