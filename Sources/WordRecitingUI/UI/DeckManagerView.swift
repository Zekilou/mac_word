import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WordRecitingCore

/// 词库管理视图：Deck 列表 + 导入按钮。
/// @ai: 严格贴合 user_profile：紧凑 UI、重要按钮在显眼位置。
struct DeckManagerView: View {
    let world: World
    @State private var viewModel: DeckManagerViewModel?
    @State private var showFilePicker = false
    /// 待删除的词库（非 nil 时弹出二次确认）。
    @State private var pendingDeletion: DeckSummary?

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
            } else {
                ProgressView().onAppear {
                    viewModel = DeckManagerViewModel(world: world)
                    viewModel?.reload()
                }
            }
        }
    }

    private func content(vm: DeckManagerViewModel) -> some View {
        NavigationStack {
            deckList(vm)
                .navigationDestination(for: DeckSummary.self) { deck in
                    CardBrowserView(
                        world: world,
                        deckId: deck.id,
                        deckName: deck.name)
                }
        }
    }

    private func deckList(_ vm: DeckManagerViewModel) -> some View {
        // @ai: 页面骨架接管工具条底、工具条内边距与内容区边距（`Space.page`）；
        //      页面不再自己写顶层 `VStack(spacing: 0)` + `.padding(...)` + `Rule()`。
        //      骨架本身不滚动（`scrolls: false`），因为「空态要占满视口居中」和
        //      「有词库时列表要滚动」是两种诉求，交给各自的 `PageBody` 决定。
        PageScaffold(contentPadding: 0, scrolls: false) {
            // 工具栏：导入按钮
            DButton("导入词库", rank: .primary, icon: "square.and.arrow.down",
                    disabled: vm.isImporting) { showFilePicker = true }

            if vm.isImporting {
                ProgressView(value: vm.importProgress)
                    .frame(width: Size.meterShort)
                Text("导入中…").font(Type.caption).foregroundStyle(Ink.secondary)
            }
            Spacer()
            // 词书从哪来——用户新装 App 时不知道 .apkg 去哪下载，
            // 这里给明文入口（AnkiWeb 官方共享词库 + CSV 格式说明）。
            DButton("去 AnkiWeb 找词书", rank: .quiet, icon: "safari",
                    help: "打开 AnkiWeb 共享词库，下载 .apkg 后可在此导入") {
                NSWorkspace.shared.open(Self.ankiWebURL)
            }
        } content: {
            VStack(spacing: 0) {
                // 消息区：通栏提示条（保持贴边，不随页面边距内缩）。
                if let err = vm.errorMessage {
                    banner(text: err, color: .red)
                }
                if let summary = vm.lastImportSummary {
                    banner(text: summary, color: .green)
                }

                // Deck 列表
                if vm.decks.isEmpty {
                    PageBody(scrolls: false) { emptyState(vm) }
                } else {
                    // @ai: 不用 List（NSTableView），避免 macOS 27 FocusBridge 布局时 key view loop 崩溃
                    PageBody {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(vm.decks) { deck in
                                HStack(spacing: Space.m) {
                                    NavigationLink(value: deck) {
                                        deckRow(deck)
                                    }
                                    .buttonStyle(.plain)
                                    IconButton(
                                        icon: "trash",
                                        help: "删除该词库（卡片一并删除，词汇掌握度保留）",
                                        tint: .red
                                    ) { pendingDeletion = deck }
                                }
                            }
                        }
                    }
                }
            }
        }
        // 删除二次确认：不可撤销，且要让用户知道「掌握度会保留」。
        .confirmationDialog(
            pendingDeletion.map { "删除词库「\($0.name)」？" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let deck = pendingDeletion { vm.deleteDeck(deck) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("将删除该词库的 \(pendingDeletion?.cardCount ?? 0) 张卡片与词条学习目标。"
                 + "你对这些词标记的「会 / 不会」与复习进度会保留（全局词汇认知，跨词库共享）。")
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.archive, .commaSeparatedText, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    vm.importFile(at: url)
                }
            case .failure(let error):
                vm.errorMessage = "文件选择失败：\(error)"
            }
        }
    }

    /// 空状态：没有词库时最关键的不是「按钮在哪」，而是「词书从哪来」。
    /// @ai: 新用户不知道 .apkg 是什么、去哪下载——这里把三条获取路径写清楚，
    ///      并直接给出 AnkiWeb 入口（最主流）、CSV 格式说明（自己整理词表）。
    private func emptyState(_ vm: DeckManagerViewModel) -> some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "tray")
                .font(IconSize.hero)
                .foregroundStyle(Ink.tertiary)
            Text("还没有词库")
                .font(Type.section)

            VStack(alignment: .leading, spacing: Space.l) {
                stepRow(
                    number: 1,
                    title: "去 AnkiWeb 下载词书",
                    detail: "AnkiWeb 有大量免费共享词书（四六级 / 考研 / 托福 / 雅思 / GRE…），"
                          + "下载后是 .apkg 文件。",
                    actionLabel: "打开 AnkiWeb",
                    action: { NSWorkspace.shared.open(Self.ankiWebURL) })
                stepRow(
                    number: 2,
                    title: "导入下载的 .apkg",
                    detail: "点左上角「导入词库」选择刚下载的文件，几十秒即可导入完成。",
                    actionLabel: nil, action: nil)
                stepRow(
                    number: 3,
                    title: "或者导入自己的 CSV",
                    detail: "表头需包含 lemma/headword/word 之一（词），可选 front/back、pos、音标、tags。"
                          + "UTF-8 编码。",
                    actionLabel: nil, action: nil)
            }
            .frame(maxWidth: 520, alignment: .leading)

            HStack(spacing: Space.m) {
                DButton("导入词库", rank: .primary, icon: "square.and.arrow.down",
                        disabled: vm.isImporting) { showFilePicker = true }
            }
            .padding(.top, Space.xs)
        }
        // 页面级留白由 `PageBody` 提供，这里只保留「占满视口居中」的原有层级。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 引导步骤行：序号徽标 + 标题 + 说明 +（可选）行内按钮。
    private func stepRow(
        number: Int, title: String, detail: String,
        actionLabel: String?, action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text("\(number)")
                .font(Type.captionEmphasis)
                .foregroundStyle(.white)
                .frame(width: Size.iconSmall, height: Size.iconSmall)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Type.bodyMedium)
                Text(detail)
                    .font(Type.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionLabel, let action {
                    DButton(actionLabel, rank: .quiet, action: action)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// AnkiWeb 共享词库首页。
    private static let ankiWebURL = URL(string: "https://ankiweb.net/shared/decks")!

    private func deckRow(_ deck: DeckSummary) -> some View {        HStack(spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(deck.name).font(Type.bodyMedium)
                HStack(spacing: Space.m) {
                    if let kind = deck.sourceKind {
                        tagView(kind)
                    }
                    Text("\(deck.cardCount) 张卡片")
                        .font(Type.caption)
                        .foregroundStyle(Ink.secondary)
                }
            }
            Spacer()
            Text(deck.createdAt, format: .dateTime.month().day().year())
                .font(Type.caption)
                .foregroundStyle(Ink.tertiary)
        }
        .padding(.vertical, Space.xs)
    }

    private func tagView(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Type.micro)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
    }

    private func banner(text: String, color: Color) -> some View {
        Text(text)
            .font(Type.caption)
            .foregroundStyle(color)
            .padding(.horizontal, Space.rowH)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08))
    }
}
