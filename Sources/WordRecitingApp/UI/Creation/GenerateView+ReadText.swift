import SwiftUI

/// GenerateView 的阅读区扩展：词块布局（每个词一个词块，带全局掌握度状态）。
/// 目标词（isTarget）为橙色词块，点击看释义并复习评分；非目标词按掌握度显示状态色，点击切换。
/// @ai: 词级粒度（FlowWordsLayout 自然断行）——修复旧 ReadFlowLayout 大段文本把目标词挤到独立一行的排版问题；
///      状态判定统一走 WordMarkState（与初始化段落/RSS 同口径）。
extension GenerateView {

    /// 渲染 token：词块 / 标点（空白跳过，间距由 FlowWordsLayout 提供）。
    enum ReadTok {
        case word(ArticleWordToken)
        case punct(String)
    }

    /// 带序号 id 的渲染 token（ForEach 稳定标识）。
    struct ReadTokItem: Identifiable {
        let id: Int
        let tok: ReadTok
    }

    /// 词块 + 标点交替排列（词用 makeArticleWords 的区间匹配，标点单独渲染）。
    static func readTokens(of body: String, words: [ArticleWordToken]) -> [ReadTokItem] {
        let chars = Array(body)
        var result: [ReadTokItem] = []
        var wordIdx = 0
        var i = 0
        while i < chars.count {
            if wordIdx < words.count, words[wordIdx].start == i {
                let w = words[wordIdx]
                result.append(ReadTokItem(id: result.count, tok: .word(w)))
                i = w.end
                wordIdx += 1
            } else {
                let ch = chars[i]
                // 空白不渲染（词块间距由 FlowWordsLayout.spacing 提供）
                if !ch.isWhitespace {
                    result.append(ReadTokItem(id: result.count, tok: .punct(String(ch))))
                }
                i += 1
            }
        }
        return result
    }

    /// 词块正文：目标词橙色（可点复习评分），非目标词状态色（可点切换掌握度）。
    /// @ai: ensureArticleWords 带 body 守卫（body 相同零副作用返回）——body 求值中执行 SQL/写
    ///       @Observable 状态会触发观察→重求值重入循环 + 每帧全表 SQL，造成彩虹圈卡死（2026-08-12 已修）。
    func articleFlow(body: String, spans: [SpanInfo]) -> some View {
        vm.ensureArticleWords(body: body, spans: spans)
        let tokens = Self.readTokens(of: body, words: vm.articleWords)
        return FlowWordsLayout(spacing: 3) {
            ForEach(tokens) { item in
                switch item.tok {
                case .word(let w):
                    if w.isTarget {
                        targetWordChip(w)
                    } else {
                        stateWordChip(w)
                    }
                case .punct(let p):
                    Text(p).font(.body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    /// 可点击目标词词块：橙色高亮；已评分的显示为绿色。点击弹释义 + 认识/不认识。
    private func targetWordChip(_ token: ArticleWordToken) -> some View {
        let rated = vm.ratedLemmaIds.contains(token.lemmaId ?? "")
        return Button {
            tappedToken = token
        } label: {
            Text(token.surface)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill((rated ? Color.green : Color.orange).opacity(0.22))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("目标词：查看释义并标记认识/不认识")
    }

    /// 非目标词词块：按掌握度显示状态色（会绿/不会红/学习中渐变/见过蓝/未见灰），点击切换。
    /// @ai: 左键统一标不会（可预测）；改会/不会走右键菜单（可逆操作不用 alert 打断）。
    private func stateWordChip(_ token: ArticleWordToken) -> some View {
        let state = vm.articleMarkState(for: token)
        return Button {
            vm.markUnknownArticleWord(token)
        } label: {
            Text(token.surface)
                .font(.body)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(state.color.opacity(0.85))
                .foregroundStyle(state == .pending ? Color.primary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("标为会") { vm.setArticleWordExtreme(token, known: true) }
            Button("标为不会") { vm.setArticleWordExtreme(token, known: false) }
        }
        .help(articleWordHelpText(for: state))
    }

    private func articleWordHelpText(for state: WordMarkState) -> String {
        switch state {
        case .known: return "已会（左键标不会；右键可改）"
        case .unknown: return "不会（右键可改为会）"
        case .learning(let belief): return "\(MasteryPresentation.helpText(belief))；左键标不会，右键改极端"
        case .seen: return "出现过未确认，模型尚无概率（左键标不会）"
        case .pending: return "无记录（左键标不会）"
        }
    }

    /// 点击目标词后的弹窗：释义 + 认识/不认识。
    func readingPopover(_ token: ArticleWordToken) -> some View {
        let definition = vm.cardForReading(token.lemmaId ?? "")?.definition
        return VStack(alignment: .leading, spacing: 12) {
            Text(token.surface).font(.title3.weight(.semibold))
            Text(definition ?? "词库中暂无释义")
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            HStack(spacing: 8) {
                Button {
                    markReading(token, .good)
                } label: {
                    Label("认识", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                Button {
                    markReading(token, .again)
                } label: {
                    Label("不认识", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    /// 标记目标词并关闭弹窗（走 StudySystem 调度）。
    private func markReading(_ token: ArticleWordToken, _ rating: Rating) {
        if let lemmaId = token.lemmaId {
            vm.markReadingWord(lemmaId: lemmaId, rating: rating)
        }
        tappedToken = nil
    }
}
