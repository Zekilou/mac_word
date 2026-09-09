import SwiftUI

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
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { vm.refreshOverview() }
    }

    // MARK: - 顶部：说明 + 掌握度概览 + 次级导航

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("词汇")
                .font(.title3).fontWeight(.semibold)
            Text("你掌握的词汇是全局上下文（context clue），用于后续所有文章选词；"
                 + "状态与卡片彻底分离，只记会不会，不建卡。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                overviewChip(value: vm.overview.known, label: "已会", color: .green)
                overviewChip(value: vm.overview.unknown, label: "不会", color: .red)
                overviewChip(value: vm.overview.seen, label: "出现过", color: .blue)
                overviewChip(value: vm.overview.unmarked, label: "未标记", color: .secondary)
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
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
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if mode == .initFlow, vm.hasParagraph {
                    Button("重新生成一段") { vm.reset() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
        }
        .padding(16)
    }

    private func overviewChip(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(value) \(label)")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - 主区

    @ViewBuilder
    private var content: some View {
        if mode == .wordList {
            VocabularyListView(world: world)
        } else {
            switch vm.stage {
            case .idle:
                emptyState
            case .generating:
                ProgressView("正在生成初始化段落…")
                    .padding(40)
            case .ready:
                paragraphEditor
            case .submitting:
                ProgressView("正在记录你的词汇…")
                    .padding(40)
            case .done:
                doneState
            }
        }
    }

    // MARK: - 首次引导

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("先让我了解你的词汇量")
                .font(.headline)
            Text("我会生成一段日常英文，你把不会的词标出来，其余自动记为已掌握。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("生成模型：\(vm.generationModelLabel)（在「设置」中修改）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                vm.generate(ease: .medium)
            } label: {
                Label("生成一段英文", systemImage: "sparkles")
                    .padding(.horizontal, 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let msg = vm.errorMessage {
                Text(msg).font(.callout).foregroundStyle(.red)
            }
        }
        .padding(40)
    }

    // MARK: - 标记段落

    private var paragraphEditor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    legend
                    FlowWordsLayout(spacing: 3) {
                        ForEach(Self.tokens(of: vm.paragraph)) { tok in
                            if tok.isWord,
                               let word = vm.words.first(where: {
                                   $0.lemma == WordNormalizer.normalize(tok.text.lowercased())
                               }) {
                                wordChip(word)
                            } else {
                                Text(tok.text)
                                    .font(.system(size: 17))
                            }
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
                }
                .padding(16)
            }
            Divider()
            bottomBar
        }
    }

    /// 图例 + 新词统计 + 操作提示。
    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle().fill(Color.green.opacity(0.85)).frame(width: 8, height: 8)
                Text("已会").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.85)).frame(width: 8, height: 8)
                Text("不会").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Color(hue: 120 / 360, saturation: 0.8, brightness: 0.8))
                    .frame(width: 8, height: 8)
                Text("学习中").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                Text("未记录").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("新词 \(vm.newWordCount)").font(.callout).foregroundStyle(Color.accentColor)
            }
            Spacer()
            Text("左键标不会 · 右键改会/不会 · 提交时统一落库")
                .font(.callout).foregroundStyle(.secondary)
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
                .font(.system(size: 17))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    state == .pending
                        ? AnyShapeStyle(.quaternary.opacity(0.35))
                        : AnyShapeStyle(state.color.opacity(0.85))
                )
                .foregroundStyle(state == .pending ? Color.primary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
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
            Button("太难了，换更简单的") { vm.regenerateSimpler() }
                .buttonStyle(.bordered)
                .help("用更基础的词重新生成一段")
            Spacer()
            if let msg = vm.errorMessage {
                Text(msg).font(.callout).foregroundStyle(.red)
            }
            Button {
                vm.submit()
            } label: {
                Label("提交词汇记录", systemImage: "checkmark.circle")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.words.isEmpty)
        }
        .padding(12)
    }

    // MARK: - 完成

    private var doneState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("记录完成")
                .font(.headline)
            Text("本次新增记录 \(vm.submittedCount) 个词：")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                VStack {
                    Text("\(vm.submittedCount - vm.newUnknownCount)").font(.title2).bold()
                    Text("已会").font(.callout).foregroundStyle(.secondary)
                }
                VStack {
                    Text("\(vm.newUnknownCount)").font(.title2).bold()
                    Text("不会").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("这些词已写入全局词汇掌握度，后续生成文章时会结合你的词汇量选词。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("再生成一段") { vm.reset() }
                    .buttonStyle(.bordered)
                Button("完成") { vm.refreshOverview() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
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
