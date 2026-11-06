import SwiftUI
import WordRecitingCore

/// 词汇初始化页：LLM 生成易读段落 → 点击词块标"不会"（剩余默认会）→ 提交全局掌握度。
/// 状态与卡片彻底分离：这里只记会不会，不建卡。
/// 顶部次级导航：初始化段落 / 已记录词汇（统一全局掌握度口径）。
/// @ai: 词块用 ReadFlowLayout 流式换行；不用 List（macOS 27 beta 拖分栏崩溃规避）。
struct VocabularyInitView: View {
    enum VocabMode: String, CaseIterable, Identifiable {
        case initFlow = "初始化段落"
        case wordList = "已记录词汇"
        var id: String { rawValue }
    }

    let world: World
    @State private var vm: VocabularyInitViewModel
    @State private var mode: VocabMode = .initFlow

    init(world: World) {
        self.world = world
        _vm = State(initialValue: VocabularyInitViewModel(world: world))
    }

    var body: some View {
        // @ai: 外层走 `PageScaffold`（工具条底 / 内边距 / 分隔线由骨架统一）。
        //      标题行进 `toolbar`；主体进 `content`，由骨架接管页面级边距与滚动。
        //      各 stage 的切换逻辑保持原样，只是外壳换成了骨架。
        //      需要自带滚动与底部操作栏的 stage（标记段落）改由自己滚，故 `scrolls: false`；
        //      各 stage 的页面级边距再统一由 `PageBody` 提供（本页 `contentPadding: 0`），
        //      这样「正文滚动区有页面边距、底部操作栏贴边」的原有层级不会变。
        PageScaffold(contentPadding: 0, scrolls: false) {
            header
        } content: {
            content
        }
        .onAppear { vm.refreshOverview() }
    }

    // MARK: - 顶部：说明 + 掌握度概览 + 次级导航

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("词汇")
                .font(Type.title)
            InfoHint(text: "词汇是全局上下文，用于后续文章选词。只记会不会，不建卡。")
                .foregroundStyle(Ink.secondary)
            HStack(spacing: Space.l) {
                overviewChip(value: vm.overview.known, label: "已会", color: .green)
                overviewChip(value: vm.overview.unknown, label: "不会", color: .red)
                overviewChip(value: vm.overview.seen, label: "出现过", color: .blue)
                overviewChip(value: vm.overview.unmarked, label: "未标记", color: .secondary)
                Spacer()
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Picker("", selection: $mode) {
                        ForEach(VocabMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 250)
                    Text(mode == .initFlow
                         ? "一次性引导：生成易读段落，标出不认识的词，建立初始掌握度"
                         : "日常档案：查看、搜索、筛选所有有记录的词")
                        .font(Type.micro)
                        .foregroundStyle(Ink.tertiary)
                }
                if mode == .initFlow, vm.hasParagraph {
                    DButton("重新生成一段", rank: .quiet) { vm.reset() }
                }
            }
            .padding(.vertical, Space.xxs)
        }
        // 页面级留白由 `PageScaffold` 工具条提供，这里不再叠 `.padding(Space.page)`；
        // 补 `maxWidth` 让标题行在工具条里仍然通栏左对齐（与迁移前一致）。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overviewChip(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: Space.xs) {
            Circle().fill(color).frame(width: Size.dot, height: Size.dot)
            Text("\(value) \(label)")
                .font(Type.caption).foregroundStyle(Ink.secondary)
        }
    }

    // MARK: - 主区

    @ViewBuilder
    private var content: some View {
        if mode == .wordList {
            // @ai: 词表自带筛选条 + 滚动，页面边距由它内部按行处理。
            VocabularyListView(world: world)
        } else {
            switch vm.stage {
            case .idle:
                // 页面级边距统一交给 `PageBody`（= `Space.page`），页面里不再手写。
                PageBody { emptyState }
            case .generating:
                PageBody { ProgressView("正在生成初始化段落…") }
            case .ready:
                paragraphEditor
            case .submitting:
                PageBody { ProgressView("正在记录你的词汇…") }
            case .done:
                PageBody { doneState }
            }
        }
    }

    // MARK: - 首次引导

    private var emptyState: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "person.text.rectangle")
                .font(IconSize.hero)
                .foregroundStyle(Color.accentColor)
            Text("先让我了解你的词汇量")
                .font(Type.section)
            Text("生成一段英文，标出不会的词。")
                .font(Type.caption)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("生成模型：\(vm.generationModelLabel)（在「设置」中修改）")
                .font(Type.micro)
                .foregroundStyle(Ink.tertiary)
            DButton("生成一段英文", rank: .primary, icon: "sparkles") {
                vm.generate(ease: .medium)
            }
            if let msg = vm.errorMessage {
                Text(msg).font(Type.caption).foregroundStyle(.red)
            }
        }
        // 页面级留白与滚动由 `PageBody` 提供，这里不再写 `.padding(Space.xxxl)`。
        .frame(maxWidth: .infinity)
    }

    // MARK: - 标记段落

    private var paragraphEditor: some View {
        // 页面级边距与滚动由 `PageBody` 给；这里只保留「正文区可滚 + 底部操作栏固定」的结构，
        // 所以底部操作栏放在 `PageBody` 之外（保持原来贴边、不随正文滚动的层级）。
        VStack(spacing: 0) {
            PageBody {
                VStack(alignment: .leading, spacing: Space.l) {
                    legend
                    Card(padding: Space.page) {
                        FlowWordsLayout(spacing: Space.xxs) {
                            ForEach(Self.tokens(of: vm.paragraph)) { tok in
                                if tok.isWord,
                                   let word = vm.words.first(where: {
                                       $0.lemma == WordNormalizer.normalize(tok.text.lowercased())
                                   }) {
                                    wordChip(word)
                                } else {
                                    Text(tok.text)
                                        .font(Type.lead)
                                }
                            }
                        }
                    }
                }
            }
            Rule()
            bottomBar
        }
    }

    /// 图例 + 新词统计 + 操作提示。
    private var legend: some View {
        HStack(spacing: Space.l) {
            HStack(spacing: Space.xs) {
                Circle().fill(Color.green.opacity(0.85)).frame(width: Size.dot, height: Size.dot)
                Text("已会").font(Type.caption).foregroundStyle(Ink.secondary)
            }
            HStack(spacing: Space.xs) {
                Circle().fill(Color.red.opacity(0.85)).frame(width: Size.dot, height: Size.dot)
                Text("不会").font(Type.caption).foregroundStyle(Ink.secondary)
            }
            HStack(spacing: Space.xs) {
                Circle().fill(Color(hue: 120 / 360, saturation: 0.8, brightness: 0.8))
                    .frame(width: Size.dot, height: Size.dot)
                Text("学习中").font(Type.caption).foregroundStyle(Ink.secondary)
            }
            HStack(spacing: Space.xs) {
                Circle().fill(Color.gray.opacity(0.5)).frame(width: Size.dot, height: Size.dot)
                Text("未记录").font(Type.caption).foregroundStyle(Ink.secondary)
            }
            HStack(spacing: Space.xs) {
                Image(systemName: "sparkles")
                Text("新词 \(vm.newWordCount)").font(Type.caption).foregroundStyle(Color.accentColor)
            }
            Spacer()
            Text("左键标不会 · 右键改")
                .font(Type.caption).foregroundStyle(Ink.secondary)
        }
    }

    /// 可点击词块：已会→绿、不会→红、学习中→掌握度渐变、无记录→极淡灰。
    /// @ai: 左键统一标不会（可预测）；改会/不会走右键菜单（可逆操作不用 alert 打断）。
    private func wordChip(_ word: InitWord) -> some View {
        let state = vm.markState(for: word)
        return Button {
            vm.markUnknown(word)
        } label: {
            Text(word.surface)
                .font(Type.lead)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .background(
                    state == .pending
                        ? AnyShapeStyle(.quaternary.opacity(0.35))
                        : AnyShapeStyle(state.color.opacity(0.85))
                )
                .foregroundStyle(state == .pending ? Color.primary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("标为会") { vm.setSession(word, known: true) }
            Button("标为不会") { vm.setSession(word, known: false) }
        }
        .help(helpText(for: state))
    }

    private func helpText(for state: WordMarkState) -> String {
        switch state {
        case .known: return "已会（左键标不会；右键可改）"
        case .unknown: return "不会（右键可改为会）"
        case .learning(let belief): return "\(MasteryPresentation.helpText(belief))；左键标不会，右键改极端"
        case .seen: return "出现过未确认，模型尚无概率（左键标不会）"
        case .pending: return "无记录（左键标不会）"
        }
    }

    /// 底部操作栏：重新生成（更简单）+ 提交。
    private var bottomBar: some View {
        HStack {
            DButton("太难了，换更简单的", rank: .secondary,
                    help: "用更基础的词重新生成一段") {
                vm.regenerateSimpler()
            }
            Spacer()
            if let msg = vm.errorMessage {
                Text(msg).font(Type.caption).foregroundStyle(.red)
            }
            DButton("提交词汇记录", rank: .primary, icon: "checkmark.circle",
                    disabled: vm.words.isEmpty) {
                vm.submit()
            }
        }
        .padding(Space.l)
    }

    // MARK: - 完成

    private var doneState: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "checkmark.circle.fill")
                .font(IconSize.hero)
                .foregroundStyle(.green)
            Text("记录完成")
                .font(Type.section)
            Text("本次新增记录 \(vm.submittedCount) 个词：")
                .font(Type.caption).foregroundStyle(Ink.secondary)
            HStack(spacing: Space.section) {
                VStack {
                    Text("\(vm.submittedCount - vm.newUnknownCount)").font(Type.title).bold()
                    Text("已会").font(Type.caption).foregroundStyle(Ink.secondary)
                }
                VStack {
                    Text("\(vm.newUnknownCount)").font(Type.title).bold()
                    Text("不会").font(Type.caption).foregroundStyle(Ink.secondary)
                }
            }
            InfoHint(text: "已写入全局词汇掌握度。")
            HStack(spacing: Space.l) {
                DButton("再生成一段", rank: .secondary) { vm.reset() }
                DButton("完成", rank: .primary) { vm.refreshOverview() }
            }
        }
        // 页面级留白与滚动由 `PageBody` 提供，这里不再写 `.padding(Space.xxxl)`。
        .frame(maxWidth: .infinity)
    }

    // MARK: - 段落分词

    /// 段落 token 化：词（字母 + - + '）+ 标点/空白，供流式词块布局。
    private struct Tok: Identifiable {
        let id: Int
        let text: String
        let isWord: Bool
    }

    private static func tokens(of text: String) -> [Tok] {
        let chars = Array(text)
        var result: [Tok] = []
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter
                    || chars[j] == "-" || chars[j] == "'" { j += 1 }
                result.append(Tok(id: result.count, text: String(chars[i..<j]), isWord: true))
                i = j
            } else {
                let ch = String(chars[i])
                // 空白不渲染（词块间距由 FlowWordsLayout.spacing 提供，避免空隙过大）
                if !ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(Tok(id: result.count, text: ch, isWord: false))
                }
                i += 1
            }
        }
        return result
    }
}

/// 词块流式换行布局（复用 ReadFlowLayout 的排布逻辑，间距紧凑接近正常文本）。
/// @ai: 不用 List；换行判断用自然宽度，避免长块被压成竖列。
struct FlowWordsLayout: Layout {
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let maxWidth = proposal.width, maxWidth.isFinite else {
            var height: CGFloat = 0
            for sub in subviews {
                height += sub.sizeThatFits(.unspecified).height + spacing
            }
            return CGSize(width: proposal.width ?? 0, height: max(0, height - spacing))
        }
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let natural = sub.sizeThatFits(.unspecified)
            if x > 0, natural.width > maxWidth - x {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            let avail = max(0, maxWidth - x)
            let size = sub.sizeThatFits(ProposedViewSize(width: avail, height: nil))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let natural = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, natural.width > bounds.maxX - x {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            let avail = max(0, bounds.maxX - x)
            let size = sub.sizeThatFits(ProposedViewSize(width: avail, height: nil))
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
