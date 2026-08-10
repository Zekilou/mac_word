import Foundation
import Observation

/// 改写 Tab 的 ViewModel：绑定源文 / 目标词输入，驱动 RuleBasedGenerator +
/// ContentGenSystem 落库，并加载生成历史。
/// @ai: UI 不写 SQL；所有写入通过 World.run(ContentGenSystem)；图查询走 GraphQueries。
@MainActor
@Observable
final class RewriteViewModel {

    // MARK: - 输入

    var sourceText: String = ""
    var targetsText: String = ""

    // MARK: - 输出

    var isGenerating: Bool = false
    var errorMessage: String?
    var resultArticle: GeneratedArticle?
    var history: [ArticleHistoryItem] = []
    var selectedArticle: StoredArticle?

    // MARK: - 依赖（常量，不参与观察）

    let world: World
    let generator: any ContentGenerator
    let constraints: GenerationConstraints = GenerationConstraints()

    init(world: World, generator: any ContentGenerator = RuleBasedGenerator()) {
        self.world = world
        self.generator = generator
    }

    // MARK: - 目标词解析

    /// 把 "A,B;C\nD" 解析为 [A,B,C,D]：按逗号 / 分号 / 换行 / 制表符切分，
    /// 去首尾空白，大小写不敏感去重，保留首次出现的大小写。
    /// 纯函数，不依赖实例状态 → nonisolated，任意上下文可调用。
    nonisolated static func parseTargets(_ text: String) -> [String] {
        let separators: Set<Character> = [",", ";", "\n", "\r", "\t"]
        var seen = Set<String>()
        var result: [String] = []
        var current = ""
        for ch in text {
            if separators.contains(ch) {
                flush(&current, into: &seen, result: &result)
            } else {
                current.append(ch)
            }
        }
        flush(&current, into: &seen, result: &result)
        return result
    }

    nonisolated private static func flush(
        _ current: inout String, into seen: inout Set<String>, result: inout [String]
    ) {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted {
            result.append(trimmed)
        }
        current = ""
    }

    // MARK: - 改写

    /// 跑一次快速改写：解析目标词 → 解析为 lemma id → 生成 → 单事务落库 → 刷新历史。
    func runRewrite() async {
        isGenerating = true
        errorMessage = nil
        selectedArticle = nil
        defer { isGenerating = false }
        do {
            let targets = Self.parseTargets(targetsText)
            let targetIds = try resolveTargetIds(targets)
            let source = sourceText.isEmpty ? nil : sourceText
            let article = try await generator.generate(
                mode: .rewrite,
                sourceText: source,
                targetLemmas: targetIds,
                constraints: constraints,
                graph: world.graph)
            try world.run(ContentGenSystem(), context: ContentGenContext(
                article: article, targetLemmas: targetIds,
                sourceText: source, topic: nil))
            resultArticle = article
            loadHistory()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// 把目标词文本逐个映射到 Lemma EntityID（findLemmaId 大小写不敏感）。
    /// 未匹配的目标词静默跳过。
    private func resolveTargetIds(_ targets: [String]) throws -> [EntityID] {
        var ids: [EntityID] = []
        for t in targets {
            if let id = try world.graph.findLemmaId(byTextA: t.lowercased()) {
                ids.append(id)
            }
        }
        return ids
    }

    // MARK: - 历史

    /// 刷新最近 20 条改写历史。
    func loadHistory() {
        do {
            history = try world.graph.recentArticles(mode: .rewrite, limit: 20)
        } catch {
            history = []
        }
    }

    /// 选中一条历史 → 加载完整 Article 回看。
    func selectHistory(_ id: EntityID) {
        resultArticle = nil
        do {
            selectedArticle = try world.graph.loadArticle(id: id)
        } catch {
            selectedArticle = nil
        }
    }
}
