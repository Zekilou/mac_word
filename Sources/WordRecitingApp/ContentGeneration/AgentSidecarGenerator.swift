import Foundation

/// Sidecar 生成器（ContentGenerator 实现）：数据（词/释义/同义词）由 App 查好随请求发送，
/// sidecar 无状态纯计算（OpenAI Agents SDK 编排：guardrail 拦截 + 覆盖校验 + 自动修正）。
/// 事件流（stage/thought/token）→ GenProgress 转发；result → GeneratedArticle（含跳过词报告）。
/// @ai: 回退——sidecar 启动失败/崩溃/超时/错误事件 → 转交给注入的 fallback 生成器
///      （通常为 LocalLLMGenerator），保证离线可用性；不落库，落库由 ContentGenSystem 负责。
struct AgentSidecarGenerator: ContentGenerator {
    static let identifier = "agent-sidecar"
    static let tier: QualityTier = .local

    let client: AgentSidecarClient
    let spec: AgentSidecarModelSpec
    var onProgress: (@Sendable (GenProgress) -> Void)?
    /// 回退生成器（sidecar 不可用时接管）。
    let fallback: (any ContentGenerator)?

    init(
        client: AgentSidecarClient, spec: AgentSidecarModelSpec,
        onProgress: (@Sendable (GenProgress) -> Void)? = nil,
        fallback: (any ContentGenerator)? = nil
    ) {
        self.client = client
        self.spec = spec
        self.onProgress = onProgress
        self.fallback = fallback
    }

    func generate(
        mode: GenerationMode,
        sourceText: String?,
        targetLemmas: [EntityID],
        constraints: GenerationConstraints,
        graph: GraphQueries
    ) async throws -> GeneratedArticle {
        do {
            return try await generateViaSidecar(
                mode: mode, sourceText: sourceText, targetLemmas: targetLemmas,
                constraints: constraints, graph: graph)
        } catch let error as AgentSidecarError {
            onProgress?(.thought(GenThought(
                id: "sidecar", kind: .info,
                message: "Agent 管线不可用（\(error.localizedDescription)），回退本地管线",
                detail: nil, status: .failed)))
            guard let fallback else { throw error }
            return try await fallback.generate(
                mode: mode, sourceText: sourceText, targetLemmas: targetLemmas,
                constraints: constraints, graph: graph)
        }
    }

    // MARK: - 内部

    private func generateViaSidecar(
        mode: GenerationMode,
        sourceText: String?,
        targetLemmas: [EntityID],
        constraints: GenerationConstraints,
        graph: GraphQueries
    ) async throws -> GeneratedArticle {
        let surfaces = try graph.lemmaSurfaces(for: targetLemmas)
        let words = surfaces.values.sorted()
        let theme = (sourceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? sourceText!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (constraints.topic ?? "")

        var params: [String: Any] = [
            "mode": mode == .generate ? "generate" : "rewrite",
            "theme": theme,
            "words": words,
            "definitions": makeDefinitions(graph: graph, surfaces: surfaces),
            "synonyms": makeSynonyms(graph: graph, targetLemmas: targetLemmas, surfaces: surfaces),
            "maxWords": constraints.maxWords,
        ]
        if mode == .rewrite, let sourceText, !sourceText.isEmpty {
            params["sourceText"] = sourceText
        }
        params["model"] = spec.jsonObject()

        let stream = try client.generate(params: params)
        var body = ""
        var skipped: [SkippedWord] = []
        do {
            for try await event in stream {
                switch event {
                case .stage(_, let stage):
                    onProgress?(.stage(stage))
                case .thought(_, let thought):
                    onProgress?(.thought(thought))
                case .token(_, let text):
                    onProgress?(.token(text))
                case .result(_, let article, let sk):
                    body = article
                    skipped = sk
                case .error(_, _, let message):
                    throw AgentSidecarError.respondedError(message)
                case .pong:
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }

        guard !body.isEmpty, !LocalLLMGenerator.isNoArticle(body) else {
            throw ArticleGenError.noArticle
        }
        let spans = LocalLLMGenerator.findTargetSpans(body: body, surfaces: surfaces)
        return GeneratedArticle(
            body: body, spans: spans,
            generatorId: Self.identifier, tier: Self.tier,
            skippedWords: skipped)
    }

    /// 目标词 → 主释义（sidecar 的 lookup_word 工具查词义用；无记录留空由 Python 侧提示）。
    private func makeDefinitions(
        graph: GraphQueries, surfaces: [EntityID: String]
    ) -> [String: String] {
        var defs: [String: String] = [:]
        for (id, word) in surfaces {
            guard let first = (try? graph.lemmaDefinitions(lemmaId: id))?.first?.definition,
                  !first.isEmpty else { continue }
            defs[word] = TextSanitizer.clean(first, preserveLineBreaks: false) ?? first
        }
        return defs
    }

    /// 目标词 → 同义词表面形式（maps_to 边双向聚合；仅目标词集内，防全库扫描噪音）。
    private func makeSynonyms(
        graph: GraphQueries, targetLemmas: [EntityID], surfaces: [EntityID: String]
    ) -> [String: [String]] {
        let targetSet = Set(targetLemmas)
        let mapping = (try? graph.listAllSynonymMappings()) ?? []
        var syns: [String: [String]] = [:]
        let surfaceByID = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.key, $0.value) })
        for m in mapping where targetSet.contains(m.fromLemmaId) || targetSet.contains(m.toLemmaId) {
            guard m.fromLemmaId != m.toLemmaId else { continue }
            if let word = surfaceByID[m.fromLemmaId], m.toText != word {
                syns[word, default: []].append(m.toText)
            }
            if let word = surfaceByID[m.toLemmaId], m.fromText != word {
                syns[word, default: []].append(m.fromText)
            }
        }
        return syns
    }
}
