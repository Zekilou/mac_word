import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
        VStack(spacing: 0) {
            // 工具栏：导入按钮
            HStack {
                Button(action: { showFilePicker = true }) {
                    Label("导入词库", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isImporting)

                if vm.isImporting {
                    ProgressView(value: vm.importProgress)
                        .frame(width: 120)
                    Text("导入中…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // 词书从哪来——用户新装 App 时不知道 .apkg 去哪下载，
                // 这里给明文入口（AnkiWeb 官方共享词库 + CSV 格式说明）。
                Button {
                    NSWorkspace.shared.open(Self.ankiWebURL)
                } label: {
                    Label("去 AnkiWeb 找词书", systemImage: "safari")
                }
                .buttonStyle(.borderless)
                .help("打开 AnkiWeb 共享词库，下载 .apkg 后可在此导入")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // 消息区
            if let err = vm.errorMessage {
                banner(text: err, color: .red)
            }
            if let summary = vm.lastImportSummary {
                banner(text: summary, color: .green)
            }

            Divider()

            // Deck 列表
            if vm.decks.isEmpty {
                emptyState(vm)
            } else {
                // @ai: 不用 List（NSTableView），避免 macOS 27 FocusBridge 布局时 key view loop 崩溃
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.decks) { deck in
                            HStack(spacing: 8) {
                                NavigationLink(value: deck) {
                                    deckRow(deck)
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) {
                                    pendingDeletion = deck
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .help("删除该词库（卡片一并删除，词汇掌握度保留）")
                            }
                            .padding(.trailing, 16)
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
        VStack(spacing: 18) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("还没有词库")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
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

            HStack(spacing: 10) {
                Button {
                    showFilePicker = true
                } label: {
                    Label("导入词库", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isImporting)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 引导步骤行：序号徽标 + 标题 + 说明 +（可选）行内按钮。
    private func stepRow(
        number: Int, title: String, detail: String,
        actionLabel: String?, action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionLabel, let action {
                    Button(actionLabel, action: action)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// AnkiWeb 共享词库首页。
    private static let ankiWebURL = URL(string: "https://ankiweb.net/shared/decks")!

    private func deckRow(_ deck: DeckSummary) -> some View {        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.name).fontWeight(.medium)
                HStack(spacing: 8) {
                    if let kind = deck.sourceKind {
                        tagView(kind)
                    }
                    Text("\(deck.cardCount) 张卡片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(deck.createdAt, format: .dateTime.month().day().year())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func tagView(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func banner(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08))
    }
}
