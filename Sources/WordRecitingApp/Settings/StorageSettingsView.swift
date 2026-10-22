import SwiftUI
import AppKit

/// 设置-储存（spec §4.3）：数据存储（位置/大小）+ 模型存储（目录/占用）+ 空间清理。
/// @ai: 纯文件系统 + World.run 清理系统；UI 不直接写 SQL。
struct StorageSettingsView: View {
    let world: World

    @State private var dbSize: Int64 = 0
    @State private var modelTotalBytes: Int64 = 0
    @State private var unusedModelCount = 0
    @State private var articleCount = 0
    @State private var confirmDeleteModels = false
    @State private var confirmClearHistory = false
    @State private var statusMessage: String?

    private let store = ModelStore()
    private let settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dataSection
                backupSection
                modelSection
                cleanupSection
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear(perform: refresh)
        .alert("删除未使用的模型", isPresented: $confirmDeleteModels) {
            Button("删除", role: .destructive) { deleteUnusedModels() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除模型目录中未被选用的 \(unusedModelCount) 个 GGUF 文件（当前选用的保留）。此操作不可撤销。")
        }
        .alert("清空历史文章", isPresented: $confirmClearHistory) {
            Button("清空", role: .destructive) { clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除全部 \(articleCount) 篇生成历史文章及其词关联标记。此操作不可撤销。")
        }
    }

    // MARK: - 数据存储

    private var dataSection: some View {
        section("数据存储") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("数据库位置", dataDirectory.path)
                infoRow("数据库大小", sizeText(dbSize))
                HStack(spacing: 8) {
                    Button {
                        openDataDirectory()
                    } label: {
                        Label("打开数据目录", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 备份与导出

    /// @ai: 用户数据只有一个 sqlite 文件，此前**没有任何导出入口**——误删或换机就全丢。
    ///      备份走 `VACUUM INTO` 生成一致快照；词汇 CSV 可被本 app 的导入器重新读回。
    private var backupSection: some View {
        section("备份与导出") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        backupDatabase()
                    } label: {
                        Label("备份数据库…", systemImage: "externaldrive.badge.timemachine")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        exportVocabulary()
                    } label: {
                        Label("导出词汇 CSV…", systemImage: "tablecells")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                Text("备份生成完整的 .sqlite 快照，可直接替换数据目录里的 db.sqlite 还原。"
                     + "词汇 CSV 含词形/释义/掌握度，可再导入回来。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 模型存储

    private var modelSection: some View {
        section("模型存储") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("模型目录", store.modelsDirectory.path)
                infoRow("已装模型", "\(store.discoveredModels().count) 个 · 共 \(sizeText(modelTotalBytes))")
            }
        }
    }

    // MARK: - 空间清理

    private var cleanupSection: some View {
        section("空间清理") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("删除未使用的模型")
                            .font(.body)
                        Text("删除模型目录中未被当前选用的 GGUF 文件，释放磁盘空间。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("删除 \(unusedModelCount) 个") {
                        confirmDeleteModels = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(unusedModelCount == 0)
                }
                Divider()
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("清空历史文章")
                            .font(.body)
                        Text("删除全部生成文章（造文 + 改写）及其目标词关联标记。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("清空 \(articleCount) 篇") {
                        confirmClearHistory = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(articleCount == 0)
                }
            }
        }
    }

    // MARK: - 动作

    private func refresh() {
        dbSize = fileSize(dbURL) ?? 0
        let models = store.discoveredModels()
        modelTotalBytes = models.reduce(0) { $0 + $1.fileSizeBytes }
        unusedModelCount = store.unusedModels(selectedPath: settings.localModelPath).count
        articleCount = (try? world.graph.articleCount()) ?? 0
    }

    private func deleteUnusedModels() {
        let fm = FileManager.default
        let unused = store.unusedModels(selectedPath: settings.localModelPath)
        var deleted = 0
        for model in unused {
            if (try? fm.removeItem(at: model.url)) != nil {
                deleted += 1
            }
        }
        statusMessage = deleted > 0 ? "已删除 \(deleted) 个未使用模型。" : "没有可删除的模型。"
        refresh()
    }

    private func clearHistory() {
        do {
            try world.run(ArticleCleanupSystem(), context: ())
            statusMessage = "已清空 \(articleCount) 篇历史文章。"
        } catch {
            statusMessage = "清空失败：\(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - 工具

    private var dataDirectory: URL {
        (try? AppIdentity.ensureSupportDirectory())
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(AppIdentity.supportDirName, isDirectory: true)
    }

    private var dbURL: URL { dataDirectory.appendingPathComponent("db.sqlite") }

    // MARK: - 备份 / 导出

    /// 选择保存位置后备份数据库。
    private func backupDatabase() {
        let panel = NSSavePanel()
        panel.title = "备份数据库"
        panel.nameFieldStringValue = DataExporter.defaultBackupFileName()
        panel.allowedContentTypes = [.database]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bytes = try DataExporter.backupDatabase(world: world, to: url)
            statusMessage = "已备份到 \(url.lastPathComponent)（\(sizeText(bytes))）"
        } catch {
            statusMessage = "备份失败：\(error)"
        }
    }

    /// 选择保存位置后导出词汇 CSV。
    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.title = "导出词汇 CSV"
        panel.nameFieldStringValue = DataExporter.defaultVocabularyFileName()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let csv = try DataExporter.exportVocabularyCSV(world: world)
            try csv.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "已导出词汇到 \(url.lastPathComponent)"
        } catch {
            statusMessage = "导出失败：\(error)"
        }
    }

    private func fileSize(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        return values?.fileSize.map(Int64.init)
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func infoRow(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func openDataDirectory() {
        NSWorkspace.shared.open(dataDirectory)
    }

    // MARK: - 复用

    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5), lineWidth: 1))
    }
}
