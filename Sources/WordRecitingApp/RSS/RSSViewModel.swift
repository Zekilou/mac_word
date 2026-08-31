import Foundation
import Observation

/// RSS 板块 ViewModel：源列表 → 文章列表 → 阅读（词块标记）。
/// 核心语义：**文章中的词自动记"出现过"（seen），不判定会/不会**——
/// 文章长、未选择的词不能默认会；用户点击词块才写会/不会（直接落库）。
/// @ai: 词块状态 = 会话标记 > 全局掌握度 > seen（蓝）> 无记录（灰）。
@MainActor
@Observable
final class RSSViewModel {

    // MARK: - 状态

    let world: World
    let store: RSSSourceStore

    /// 当前可用源（内置 + 用户自填）。
    var sources: [RSSSource] = []
    var selectedSourceId: String?
    var items: [RSSItem] = []
    var isFetchingSource = false
    var isFetchingArticle = false
    var errorMessage: String?

    /// 当前阅读的文章与提取词元。
    var selectedItem: RSSItem?
    var articleText: String = ""
    var words: [InitWord] = []

    // MARK: - 词汇状态映射（与初始化板块一致）

    private(set) var masteryByLemma: [String: Double] = [:]
    private(set) var seenByLemma: [String: Int] = [:]

    // MARK: - 测试注入

    /// 测试注入：非 nil 时用此 URLSession（绕过真实网络）。
    var sessionOverride: URLSession?

    init(world: World, store: RSSSourceStore = .shared) {
        self.world = world
        self.store = store
        reloadSources()
        reloadStates()
    }

    private var session: URLSession { sessionOverride ?? .shared }

    // MARK: - 源

    func reloadSources() {
        sources = store.all
        if selectedSourceId == nil {
            selectedSourceId = sources.first?.id
        }
    }

    /// 选择源 → 抓取文章列表。
    func selectSource(_ id: String) {
        selectedSourceId = id
        items = []
        selectedItem = nil
        words = []
        fetchSource()
    }

    func fetchSource() {
        guard let source = sources.first(where: { $0.id == selectedSourceId }),
              let url = source.url else { return }
        isFetchingSource = true
        errorMessage = nil
        Task {
            do {
                let data = try await session.data(from: url).0
                let parsed = try RSSParser.parse(data: data)
                await MainActor.run {
                    items = parsed
                    isFetchingSource = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "抓取失败：\(error.localizedDescription)"
                    isFetchingSource = false
                }
            }
        }
    }

    // MARK: - 文章阅读

    /// 打开文章：feed 全文（content:encoded）→ 仅摘要时抓原文提取正文 → 失败回退摘要 → 提取词元 → 记 seen。
    /// @ai: 只提取正文供阅读，不落库全文；抓取失败静默回退摘要。
    func selectArticle(_ item: RSSItem) {
        selectedItem = item
        words = []
        isFetchingArticle = true
        errorMessage = nil

        let content = item.content.rssCleanedText()
        let summary = item.summary.rssCleanedText()

        // 1. feed 自带全文 → 直接用
        if !content.isEmpty {
            presentArticle(text: content)
            return
        }
        // 2. 只有摘要（BBC/Guardian/NYT 等新闻源现状）→ 抓原文提取正文
        if let link = URL(string: item.link) {
            fetchFullArticle(link: link, fallback: summary)
            return
        }
        // 3. 无 link → 摘要兜底 / 结束
        if !summary.isEmpty {
            presentArticle(text: summary)
        } else {
            isFetchingArticle = false
        }
    }

    /// 抓取原文 HTML → 提取正文；失败或提取为空则回退摘要。
    private func fetchFullArticle(link: URL, fallback: String) {
        Task {
            do {
                let data = try await session.data(from: link).0
                let html = String(decoding: data, as: UTF8.self)
                let extracted = ArticleExtractor.extract(from: html)
                await MainActor.run {
                    if !extracted.isEmpty {
                        presentArticle(text: extracted)
                    } else if !fallback.isEmpty {
                        presentArticle(text: fallback)
                    } else {
                        errorMessage = "原文抓取未提取到正文"
                        isFetchingArticle = false
                    }
                }
            } catch {
                await MainActor.run {
                    if !fallback.isEmpty {
                        presentArticle(text: fallback)
                    } else {
                        errorMessage = "原文抓取失败：\(error.localizedDescription)"
                        isFetchingArticle = false
                    }
                }
            }
        }
    }

    private func presentArticle(text: String) {
        articleText = text
        words = VocabularyInitGenerator.extractWords(text)
        // 自动记录"出现过"：全部词 seen+1，mastery 不变（无记录保持 0）
        let seenWords = words.map(\.lemma)
        do {
            try world.run(UserKnownSystem(), context: .markSeen(words: seenWords, source: "rss"))
            reloadStates()
        } catch {
            errorMessage = "词汇记录失败：\(error)"
        }
        isFetchingArticle = false
    }

    // MARK: - 词汇标记

    func reloadStates() {
        masteryByLemma = (try? world.graph.knownLemmaMastery()) ?? [:]
        seenByLemma = (try? world.graph.allLemmaSeenCounts()) ?? [:]
    }

    /// 词块状态：全局掌握度（会/不会）> 出现过（seen 蓝）> 无记录（灰）。
    /// @ai: RSS 板块无会话暂存，直接以全局状态为准（点击即写库）；判定统一走 WordMarkState.from。
    func markState(for word: InitWord) -> WordMarkState {
        guard let lemmaId = try? world.graph.findLemmaId(byTextA: word.lemma) else {
            return .pending
        }
        return WordMarkState.from(
            mastery: masteryByLemma[lemmaId],
            seenCount: seenByLemma[lemmaId] ?? 0)
    }

    /// 点击词块切换并立即落库：绿→红；红→绿；蓝/灰→红。
    /// @ai: learning（学习中）由 View 弹确认后走 setExtreme，不在此切换。
    func toggle(_ word: InitWord) {
        guard let lemmaId = try? world.graph.findLemmaId(byTextA: word.lemma) else { return }
        let op: UserKnownOp
        switch markState(for: word) {
        case .known:
            op = .markUnknown(lemmaId: lemmaId, source: "rss")
        case .unknown:
            op = .markKnown(lemmaId: lemmaId, source: "rss")
        case .seen, .pending, .learning:
            op = .markUnknown(lemmaId: lemmaId, source: "rss")
        }
        do {
            try world.run(UserKnownSystem(), context: op)
            reloadStates()
        } catch {
            errorMessage = "标记失败：\(error)"
        }
    }

    /// 把词直接设置为极端掌握度（会=2 / 不会=1）。
    /// @ai: 用户确认后把"学习中"词落到两端极值；极端词修改无需确认直接走 toggle。
    func setExtreme(_ word: InitWord, known: Bool) {
        guard let lemmaId = try? world.graph.findLemmaId(byTextA: word.lemma) else { return }
        let op: UserKnownOp = known
            ? .markKnown(lemmaId: lemmaId, source: "rss")
            : .markUnknown(lemmaId: lemmaId, source: "rss")
        do {
            try world.run(UserKnownSystem(), context: op)
            reloadStates()
        } catch {
            errorMessage = "标记失败：\(error)"
        }
    }
}
