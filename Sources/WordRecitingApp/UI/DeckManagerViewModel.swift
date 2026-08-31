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
    func importFile(at url: URL) {
        isImporting = true
        importProgress = 0
        errorMessage = nil
        lastImportSummary = nil
        let world = self.world
        let activityID = GlobalActivityCenter.shared.begin(
            title: "导入词库", icon: "square.and.arrow.down",
            progress: 0.0, message: "解析中…")
        GlobalActivityCenter.shared.run(activityID) {
            // security-scoped 访问权限在任务执行期间保持
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let ext = url.pathExtension.lowercased()
                let batch: ImportBatch

                if ["apkg", "colpkg"].contains(ext) {
                    let importer = AnkiImporter()
                    guard importer.canImport(url: url) else {
                        await MainActor.run { [weak self] in self?.errorMessage = "无法识别此 .apkg 文件" }
                        return
                    }
                    batch = try await importer.readNodes(from: url) { @Sendable p in
                        Task { @MainActor in
                            GlobalActivityCenter.shared.update(activityID, progress: p)
                        }
                    }
                } else if ["csv", "tsv", "txt"].contains(ext) {
                    let importer = CSVImporter()
                    guard importer.canImport(url: url) else {
                        await MainActor.run { [weak self] in self?.errorMessage = "无法识别此 CSV 文件" }
                        return
                    }
                    batch = try await importer.readNodes(from: url) { @Sendable p in
                        Task { @MainActor in
                            GlobalActivityCenter.shared.update(activityID, progress: p)
                        }
                    }
                } else {
                    await MainActor.run { [weak self] in self?.errorMessage = "不支持的文件格式：.\(ext)" }
                    return
                }

                try world.run(ImportSystem(), context: batch)

                let nodeCount = batch.nodes.count
                let edgeCount = batch.edges.count
                let failureCount = batch.failures.count
                await MainActor.run { [weak self] in
                    self?.lastImportSummary = "导入完成：\(nodeCount) 节点，\(edgeCount) 关系，\(failureCount) 失败行"
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
}
