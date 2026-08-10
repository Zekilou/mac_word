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
    func importFile(at url: URL) async {
        isImporting = true
        importProgress = 0
        errorMessage = nil
        lastImportSummary = nil
        defer { isImporting = false }

        do {
            let ext = url.pathExtension.lowercased()
            let batch: ImportBatch

            if ["apkg", "colpkg"].contains(ext) {
                let importer = AnkiImporter()
                guard importer.canImport(url: url) else {
                    errorMessage = "无法识别此 .apkg 文件"
                    return
                }
                batch = try await importer.readNodes(from: url) { @Sendable p in
                    Task { @MainActor in self.importProgress = p }
                }
            } else if ["csv", "tsv", "txt"].contains(ext) {
                let importer = CSVImporter()
                guard importer.canImport(url: url) else {
                    errorMessage = "无法识别此 CSV 文件"
                    return
                }
                batch = try await importer.readNodes(from: url) { @Sendable p in
                    Task { @MainActor in self.importProgress = p }
                }
            } else {
                errorMessage = "不支持的文件格式：.\(ext)"
                return
            }

            try world.run(ImportSystem(), context: batch)

            let nodeCount = batch.nodes.count
            let edgeCount = batch.edges.count
            let failureCount = batch.failures.count
            lastImportSummary = "导入完成：\(nodeCount) 节点，\(edgeCount) 关系，\(failureCount) 失败行"
            reload()
        } catch {
            errorMessage = "导入失败：\(error)"
        }
    }
}
