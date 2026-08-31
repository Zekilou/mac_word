import Foundation
import Observation

/// 同义词管理 ViewModel：搜索 lemma → 添加/删除映射 → 刷新列表。
/// @ai: UI 不写 SQL；增删通过 World.run(SynonymSystem)；查询走 GraphQueries。
@MainActor
@Observable
final class SynonymManagerViewModel {

    /// 映射列表（UI 展示）。
    var mappings: [SynonymMapping] = []

    /// 左搜索框：源词输入。
    var fromSearchText: String = ""
    /// 源词候选下拉。
    var fromCandidates: [LemmaCandidate] = []
    /// 选中的源词。
    var selectedFrom: LemmaCandidate?

    /// 右搜索框：同义词输入。
    var toSearchText: String = ""
    /// 同义词候选下拉。
    var toCandidates: [LemmaCandidate] = []
    /// 选中的同义词。
    var selectedTo: LemmaCandidate?

    var errorMessage: String?
    var lastSuccessMessage: String?

    let world: World

    init(world: World) {
        self.world = world
    }

    // MARK: - 生命周期

    func onAppear() {
        reload()
    }

    // MARK: - 列表刷新

    func reload() {
        do {
            mappings = try world.graph.listAllSynonymMappings()
        } catch {
            mappings = []
            errorMessage = "加载同义词列表失败：\(error)"
        }
    }

    // MARK: - 搜索候选（debounce 由 UI 调用方控制，这里每次输入即时查）

    func updateFromCandidates() {
        let keyword = fromSearchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            fromCandidates = []
            return
        }
        do {
            fromCandidates = try world.graph.searchLemmas(prefix: keyword, limit: 30)
        } catch {
            errorMessage = "搜索失败：\(error)"
        }
    }

    func updateToCandidates() {
        let keyword = toSearchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            toCandidates = []
            return
        }
        do {
            toCandidates = try world.graph.searchLemmas(prefix: keyword, limit: 30)
        } catch {
            errorMessage = "搜索失败：\(error)"
        }
    }

    // MARK: - 添加映射

    func canAdd() -> Bool {
        guard let f = selectedFrom, let t = selectedTo else { return false }
        return f.lemmaId != t.lemmaId
    }

    func addMapping() {
        errorMessage = nil
        lastSuccessMessage = nil
        guard let f = selectedFrom, let t = selectedTo else {
            errorMessage = "请先选择源词和同义词"
            return
        }
        guard f.lemmaId != t.lemmaId else {
            errorMessage = "源词和同义词不能相同"
            return
        }
        do {
            try world.run(SynonymSystem(), context: .add(
                from: f.lemmaId, to: t.lemmaId, weight: 1.0, sourceType: "user"))
            lastSuccessMessage = "已添加：\(f.text) → \(t.text)"
            // 清空输入
            fromSearchText = ""; toSearchText = ""
            selectedFrom = nil; selectedTo = nil
            fromCandidates = []; toCandidates = []
            reload()
        } catch {
            errorMessage = "添加失败：\(error)"
        }
    }

    // MARK: - 删除映射

    func remove(mapping: SynonymMapping) {
        errorMessage = nil
        lastSuccessMessage = nil
        do {
            try world.run(SynonymSystem(), context: .removeByEdge(edgeId: mapping.edgeId))
            lastSuccessMessage = "已删除：\(mapping.fromText) → \(mapping.toText)"
            reload()
        } catch {
            errorMessage = "删除失败：\(error)"
        }
    }
}
