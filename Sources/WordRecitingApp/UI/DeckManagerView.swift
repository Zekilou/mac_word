import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 词库管理视图：Deck 列表 + 导入按钮。
/// @ai: 严格贴合 user_profile：紧凑 UI、重要按钮在显眼位置。
struct DeckManagerView: View {
    let world: World
    @State private var viewModel: DeckManagerViewModel?
    @State private var showFilePicker = false

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
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("尚未导入任何词库").foregroundStyle(.secondary)
                    Text("点击上方「导入词库」按钮选择 .apkg 或 .csv 文件")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.decks) { deck in
                    deckRow(deck)
                }
                .listStyle(.inset)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.archive, .commaSeparatedText, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        await vm.importFile(at: url)
                    }
                }
            case .failure(let error):
                vm.errorMessage = "文件选择失败：\(error)"
            }
        }
    }

    private func deckRow(_ deck: DeckSummary) -> some View {
        HStack(spacing: 12) {
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
