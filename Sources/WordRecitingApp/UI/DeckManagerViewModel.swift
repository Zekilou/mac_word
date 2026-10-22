import Foundation
import Observation

/// 词库管理 ViewModel：导入词库 + 展示 deck 列表。
/// @ai: UI 不写 SQL；导入通过 World.run(ImportSystem)；查询走 GraphQueries。
@MainActor
@Observable
final class DeckManagerViewModel {

    var decks: [DeckSummary] = []
    var isImporting: Bool = false
    var importProgress: Double = 0
    var errorMessage: String?
    var lastImportSummary: String?

    let world: World

    init(world: World) {
        self.world = world
    }

    /// 刷新 deck 列表。
    func reload() {
        do {
            decks = try world.graph.allDecks()
        } catch {
            decks = []
            errorMessage = "\(error)"
        }
    }

    /// 导入文件：自动识别 .apkg / .csv / .tsv。
    /// 导入任务托管到全局活动中心执行，切页/销毁 View 不中断；完成自动落库刷新。
    /// @ai: 所有提前返回的分支都必须复位 `isImporting`，否则按钮 `.disabled(isImporting)`
    ///      会被永久卡住（导入一个不支持的格式后，再也点不动「导入词库」）。
    ///      进度同时写进 `importProgress`（页面进度条数据源，旧实现恒为 0）。
    func importFile(at url: URL) {
        isImporting = true
        importProgress = 0
        errorMessage = nil
        lastImportSummary = nil
        let world = self.world
        let activityID = GlobalActivityCenter.shared.begin(
            title: "导入词库", icon: "square.and.arrow.down",
            progress: 0.0, message: "解析中…")

        GlobalActivityCenter.shared.run(activityID) { [weak self] in
            // security-scoped 访问权限在任务执行期间保持
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let ext = url.pathExtension.lowercased()
                let batch: ImportBatch

                // 进度回调：同时更新全局活动中心与页面进度条
                let onProgress: @Sendable (Double) -> Void = { p in
                    Task { @MainActor in
                        GlobalActivityCenter.shared.update(activityID, progress: p)
                        self?.importProgress = p
                    }
                }

                if ["apkg", "colpkg"].contains(ext) {
                    let importer = AnkiImporter()
                    guard importer.canImport(url: url) else {
                        await MainActor.run { self?.finishImportWithError("无法识别此 .apkg 文件") }
                        return
                    }
                    batch = try await importer.readNodes(from: url, progress: onProgress)
                } else if ["csv", "tsv", "txt"].contains(ext) {
                    let importer = CSVImporter()
                    guard importer.canImport(url: url) else {
                        await MainActor.run { self?.finishImportWithError("无法识别此 CSV 文件") }
                        return
                    }
                    batch = try await importer.readNodes(from: url, progress: onProgress)
                } else {
                    await MainActor.run { self?.finishImportWithError("不支持的文件格式：.\(ext)") }
                    return
                }

                try world.run(ImportSystem(), context: batch)

                let nodeCount = batch.nodes.count
                let edgeCount = batch.edges.count
                let failureCount = batch.failures.count
                await MainActor.run { [weak self] in
                    self?.lastImportSummary = "导入完成：\(nodeCount) 节点，\(edgeCount) 关系，\(failureCount) 失败行"
                    self?.importProgress = 1
                    self?.isImporting = false
                    self?.reload()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = "导入失败：\(error)"
                    self?.isImporting = false
                }
            }
        }
    }

    /// 导入早期失败的统一收尾：记录错误并复位 `isImporting`。
    /// @ai: 不复位会让「导入词库」按钮永久 `.disabled`（见 importFile 注释）。
    private func finishImportWithError(_ message: String) {
        errorMessage = message
        isImporting = false
    }

    /// 删除词库（deck + 其全部卡片）。
    /// @ai: 只删学习目标，**保留全局词汇认知**（comp_user_known / mastery_belief / 词事件）——
    ///      一个词会不会是跨词库的全局状态，重新导入同一词库不应丢复习进度。
    ///      UI 层必须先二次确认再调本方法（不可撤销）。
    func deleteDeck(_ deck: DeckSummary) {
        errorMessage = nil
        lastImportSummary = nil
        do {
            try world.run(DeckCleanupSystem(), context: .delete(deckId: deck.id))
            lastImportSummary = "已删除词库「\(deck.name)」及其 \(deck.cardCount) 张卡片"
            reload()
        } catch {
            errorMessage = "删除失败：\(error)"
        }
    }
}
