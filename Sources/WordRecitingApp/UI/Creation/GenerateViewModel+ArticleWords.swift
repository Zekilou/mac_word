import Foundation
import SwiftUI

/// 造文文章的词 token：surface + 归一 lemma + 是否目标词。
/// @ai: 词块布局用（每个词一个词块，带全局掌握度状态）；isTarget=true 的词走复习评分交互。
struct ArticleWordToken: Identifiable, Sendable {
    let id: Int
    let surface: String
    /// WordNormalizer 归一化的 lemma（状态反查/落库用）。
    let lemma: String
    /// 字符区间（span 匹配）。
    let start: Int
    let end: Int
    /// 是否为本次生成的目标词（橙色高亮 + 复习评分）。
    let isTarget: Bool
    /// 目标词对应的 lemmaId（span 提供；非目标词为 nil，运行时反查）。
    let lemmaId: EntityID?
}

// MARK: - 文章全词状态（阅读区词块）

extension GenerateViewModel {

    /// 分词 + 匹配目标词 span，构建文章词列表（词块布局数据源）。
    /// @ai: 词级粒度（字母 + - + '），与初始化段落/RSS 同口径；span 按字符区间重叠匹配。
    nonisolated static func makeArticleWords(body: String, spans: [SpanInfo]) -> [ArticleWordToken] {
        let chars = Array(body)
        var result: [ArticleWordToken] = []
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j] == "-" || chars[j] == "'" { j += 1 }
                let surface = String(chars[i..<j])
                var isTarget = false
                var lemmaId: EntityID?
                for span in spans where span.isTarget {
                    // 区间重叠：span 覆盖了该词的任何字符即命中
                    if span.start < j, span.end > i {
                        isTarget = true
                        lemmaId = span.lemmaId
                        break
                    }
                }
                result.append(ArticleWordToken(
                    id: result.count, surface: surface,
                    lemma: WordNormalizer.normalize(surface.lowercased()),
                    start: i, end: j, isTarget: isTarget, lemmaId: lemmaId))
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    /// 加载当前阅读文章的词列表（body/spans 变化时调用）。
    /// @ai: **必须在 View body 求值路径外/带守卫调用**——本方法会写 @Observable 属性并查 SQL，
    ///       body 重绘时若每次都执行会触发观察→重求值重入循环 + 每帧全表 SQL（卡死/彩虹圈根因）。
    ///       守卫键 = isGenerating + body：流式（只分词不上色）与完成态（加载掌握度上色）的 body 即使
    ///       相同也必须区分——否则流式最后一个 token 的 body 把 loadedBodyKey 占住，生成完成后 guard
    ///       直接短路，掌握度永不加载 → 全词灰（2026-08-12 修复）。
    func ensureArticleWords(body: String, spans: [SpanInfo]) {
        let key = (isGenerating ? "g:" : "i:") + body
        guard key != loadedBodyKey else { return }
        loadedBodyKey = key
        articleWords = Self.makeArticleWords(body: body, spans: spans)
        guard !isGenerating else { return }
        loadWordMastery()
        prefetchLemmaIds()
        // 文章打开 → 登记显示上下文（流式期间不登记，避免每个 token 建一个 region）
        RegionRecorder(world: world).ensure(currentArticleRegion)
    }

    /// 刷新全局掌握度与出现记录映射（与初始化段落同口径）。
    func loadWordMastery() {
        masteryByLemma = (try? world.graph.knownLemmaMastery()) ?? [:]
        seenByLemma = (try? world.graph.allLemmaSeenCounts()) ?? [:]
        beliefByLemma = (try? world.graph.allMasteryBeliefs()) ?? [:]
    }

    /// 预解析全部非目标词的 lemmaId 到缓存（一次批量反查；span 自带 id 的词直接复用）。
    /// @ai: 之后 articleMarkState 纯内存查找，渲染路径零 SQL。
    func prefetchLemmaIds() {
        var cache: [String: EntityID] = [:]
        for w in articleWords where !w.isTarget {
            guard cache[w.lemma] == nil else { continue }
            if let lid = w.lemmaId {
                cache[w.lemma] = lid
            } else if let lid = try? world.graph.findLemmaId(byTextA: w.lemma) {
                cache[w.lemma] = lid
            }
        }
        lemmaIdByWord = cache
    }

    /// 词块状态（仅非目标词）：会话覆盖 > 全局掌握度/出现过 > 无记录。
    /// @ai: 判定统一走 WordMarkState.from（与初始化段落/RSS 同一口径）；
    ///      流式生成中跳过反查（每 token 一次 SQL 会卡），完成后再上色；
    ///      缓存未命中时惰性反查一次并缓存（预解析路径之外的安全兜底）。
    func articleMarkState(for token: ArticleWordToken) -> WordMarkState {
        if token.isTarget || isGenerating { return .pending }
        if let known = sessionWordStates[token.lemma] {
            return known ? .known : .unknown
        }
        let lemmaId = lemmaIdByWord[token.lemma] ?? lazyResolveLemmaId(token)
        guard let lemmaId else { return .pending }
        return WordMarkState.from(
            belief: beliefByLemma[lemmaId],
            mastery: masteryByLemma[lemmaId],
            seenCount: seenByLemma[lemmaId] ?? 0)
    }

    /// 惰性反查 lemmaId 并写回缓存（每个词至多一次 SQL）。
    private func lazyResolveLemmaId(_ token: ArticleWordToken) -> EntityID? {
        if let lid = token.lemmaId {
            lemmaIdByWord[token.lemma] = lid
            return lid
        }
        guard let lid = try? world.graph.findLemmaId(byTextA: token.lemma) else { return nil }
        lemmaIdByWord[token.lemma] = lid
        return lid
    }

    /// 点击非目标词三态循环（复用初始化段落/RSS 逻辑）：
    ///  灰/绿/蓝/学习中 → 红；手动红 → 回灰/跟全局；记录红 → 绿。
    /// @ai: 立即落库（batch 会 findOrCreateLemma 并写极端）；learning 由 View 弹确认走 setArticleWordExtreme。
    func toggleArticleWord(_ token: ArticleWordToken) {
        switch articleMarkState(for: token) {
        case .pending, .known, .seen, .learning:
            sessionWordStates[token.lemma] = false
        case .unknown:
            if sessionWordStates[token.lemma] == false {
                sessionWordStates.removeValue(forKey: token.lemma)
            } else {
                sessionWordStates[token.lemma] = true
            }
        }
        persistArticleWordState(token)
    }

    /// 把词直接写为会话极端状态（会/不会）并落库（learning 确认后调用）。
    func setArticleWordExtreme(_ token: ArticleWordToken, known: Bool) {
        sessionWordStates[token.lemma] = known
        persistArticleWordState(token)
    }

    /// 当前生成文章的显示上下文（region id 稳定可复用；剥离流式/完成态前缀）。
    private var currentArticleRegion: RegionRef {
        var key = loadedBodyKey ?? "session"
        if key.hasPrefix("g:") || key.hasPrefix("i:") { key.removeFirst(2) }
        return RegionRef.generate(articleId: key, title: nil)
    }

    /// 把会话状态落库为全局掌握度极值（source="reading"，不建卡）。
    private func persistArticleWordState(_ token: ArticleWordToken) {
        guard let known = sessionWordStates[token.lemma] else { return }
        do {
            try world.run(
                UserKnownSystem(),
                context: .batch(words: [(token.lemma, known)], source: "reading"))
            RegionRecorder(world: world).record(
                surfaces: [token.lemma], region: currentArticleRegion,
                kind: known ? .markKnown : .markUnknown, trust: 1.0)
            loadWordMastery()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
