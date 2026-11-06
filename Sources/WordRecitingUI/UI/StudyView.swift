import SwiftUI
import WordRecitingCore

/// 背诵闪卡视图：到期卡片队列，正面词面 / 背面释义，翻面 = 实体 3D 翻转，4 键评分。
///
/// @ai: 布局与交互约定（改前先读，旧实现的问题都在这里）：
///      - **翻面是一次真实翻转**：`FlashCard` 用角度驱动 `rotation3DEffect`，
///        正反面显隐由角度推导（`CardFlipMotion`）。不要再退回「两个布尔交叉淡入淡出」。
///      - **必须先翻开才能评分**：正面的 1–4 键不生效，`canRate` 统一判定；
///        评分后短暂锁定（`lastRating`）防止连点跳过中间的卡。
///      - **卡片尺寸固定**：`StudyCardStyle.width/height`，两面同框，翻面不跳。
///      - 快捷键 1–4 = 不认识 / 有点难 / 认识 / 很熟；空格 = 翻面；S = 跳过。
/// @ai: 旧实现的 `.onTapGesture` 挂在整块 ZStack 上并靠 contentShape 补命中，
///      同时两面高度不同 —— 命中区随内容漂移，表现为「有时点了没反应」。新版由
///      `FlashCard` 自己铺满固定画布，外层不再插手命中。
struct StudyView: View {
    @State private var vm: StudyViewModel

    init(world: World) {
        _vm = State(initialValue: StudyViewModel(world: world))
    }

    /// @ai: 页面骨架接管工具条底 / 工具条内边距 / 分隔线，页面不再自己拼
    ///      `VStack(spacing: 0) { header; Rule(); content }`。
    ///      **骨架不滚动**：背诵卡是固定画布（`StudyCardStyle` 520×340），
    ///      外面套 `ScrollView` 会让里面的 `Spacer` 塌成 0、卡片贴顶且不再居中，
    ///      所以走 `scrolls: false`；页面级边距仍由 `PageBody` 统一给（`Space.page`），
    ///      页面里不再手写 `.padding(Space.page)` / `.padding(Space.xxl)`。
    var body: some View {
        PageScaffold(scrolls: false) {
            header
        } content: {
            PageBody(scrolls: false) { content }
        }
        .onAppear { vm.reload() }
    }

    // MARK: - 顶部：统计 + 本轮进度

    private var header: some View {
        HStack(alignment: .center, spacing: Space.section) {
            if let s = vm.stats {
                // @ai: 与首页/分析页同一套统计卡，不再自绘 statItem。
                HStack(spacing: Space.s) {
                    StatTile(label: "词库", value: "\(s.totalCards)",
                             icon: "rectangle.stack", tint: Ink.secondary)
                    StatTile(label: "已学", value: "\(s.studiedCards)",
                             icon: "book.fill", tint: .accentColor)
                    StatTile(label: "今日到期", value: "\(s.dueCount)",
                             icon: "clock", tint: .orange)
                    StatTile(label: "今日已复习", value: "\(s.reviewedToday)",
                             icon: "checkmark.circle", tint: .green)
                    StatTile(label: "AGAIN",
                             value: String(format: "%.0f%%", s.againRatio * 100),
                             icon: "exclamationmark.triangle", tint: .red)
                }
                .frame(maxWidth: 560)
            }
            if vm.totalInRound > 0 {
                roundProgress
            }
            Spacer()
            if vm.hasRatedCurrent {
                Button {
                    vm.undoLastRating()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .help("回到刚才那张卡（调度已经写库，这里只放回队列）")
            }
            Button { vm.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新队列（已评分的不再出现，不会重置进度）")
        }
    }

    /// 本轮进度：细条 + 分数。比单写「剩余 N 张」多给了「还剩多久」的直觉。
    private var roundProgress: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("本轮 \(vm.completedInRound) / \(vm.totalInRound)")
                .font(Type.micro)
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
            Meter(value: Double(vm.completedInRound),
                  total: Double(max(vm.totalInRound, 1)),
                  height: 4)
                .frame(width: Size.meterShort)
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let err = vm.errorMessage {
                // @ai: 页面级左右边距已由 `PageBody` 提供，这里不再叠一层
                //      `.padding(.horizontal, Space.page)`（旧实现会变成 48pt 缩进）。
                Text(err)
                    .font(Type.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, Space.m)
            }
            if let card = vm.currentCard {
                studyArea(card)
            } else {
                emptyState
            }
        }
    }

    private func studyArea(_ card: CardListItem) -> some View {
        VStack(spacing: Space.xl) {
            Spacer(minLength: 12)

            FlashCard(isFront: vm.isFront, onFlip: { vm.flip() }) {
                cardFront(card)
            } back: {
                cardBack(card)
            }

            ratingBar
            Spacer(minLength: 12)
        }
        // @ai: 只留左右留白由 `PageBody` 统一给；这里不加任何 padding，
        //      否则卡片会被再挤一圈、左右不再与工具条对齐。
        //      卡片自身 520×340 固定画布，居中靠 VStack 默认 center 对齐 + `Spacer`。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // @ai: 用 id 绑定卡片身份，换卡时若仍是同一个视图树，翻转角度状态不会串到下一张。
        .id(card.cardId)
    }

    // MARK: - 正面

    private func cardFront(_ card: CardListItem) -> some View {
        VStack(spacing: Space.l) {
            Spacer(minLength: 0)
            Text(card.plainText)
                .font(Type.displaySerif)
                .minimumScaleFactor(0.5)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .textSelection(.disabled)
            if let phonetic = vm.currentPhonetic {
                Text(phonetic)
                    .font(Type.monoLead)
                    .foregroundStyle(Ink.secondary)
                    .textSelection(.disabled)
            }
            tagsRow(showsMeaning: false)
            Spacer(minLength: 0)
            hint("点卡片或按空格看释义", symbol: "hand.tap")
        }
        .padding(.horizontal, Space.xxxl)
        .padding(.vertical, Space.xxl)
    }

    // MARK: - 背面

    private func cardBack(_ card: CardListItem) -> some View {
        VStack(spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(card.plainText)
                    .font(Type.titleLarge)
                if let phonetic = vm.currentPhonetic {
                    Text(phonetic)
                        .font(Type.caption)
                        .foregroundStyle(Ink.secondary)
                        .textSelection(.disabled)
                }
                Spacer(minLength: 0)
                if let belief = vm.currentBelief {
                    Text(MasteryPresentation.percentText(belief))
                        .font(Type.captionEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(stateColor(belief))
                        .help(MasteryPresentation.helpText(belief))
                } else {
                    Text(MasteryPresentation.noDataText)
                        .font(Type.caption)
                        .foregroundStyle(Ink.tertiary)
                        .help("模型还没有这个词的任何证据，因此没有掌握度估计")
                }
            }

            Rule().opacity(0.6)

            // 释义可能很长（含例句），固定高度内允许滚动——卡片本身不能长高，否则翻面会跳。
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if let def = card.definition, !def.isEmpty {
                        Text(def)
                            .font(Type.lead)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.disabled)
                    } else {
                        Text("（这个词还没有释义）")
                            .font(Type.caption)
                            .foregroundStyle(Ink.secondary)
                    }
                }
                .padding(.trailing, Space.xs)
            }
            .frame(maxHeight: .infinity)

            tagsRow(showsMeaning: true)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.xxl)
    }

    // MARK: - 卡面小组件

    /// 词频带 + 出现原因（正反面都显示：翻面时提供连续感，不至于背面突然多出一堆信息）。
    private func tagsRow(showsMeaning: Bool) -> some View {
        HStack(spacing: Space.m) {
            if let provenance = vm.currentProvenance {
                chip(provenance, tint: .secondary)
            }
            Text(FrequencyBandPresentation.bandLabel(vm.currentBand))
                .font(Type.micro)
                .foregroundStyle(Ink.secondary)
                .help(FrequencyBandPresentation.helpText(
                    band: vm.currentBand, rank: vm.currentRank))
            if showsMeaning, let summary = vm.currentEventSummary {
                Text(summary)
                    .font(Type.micro)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Type.micro)
            .foregroundStyle(tint)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    private func hint(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Type.caption)
            .foregroundStyle(Ink.tertiary)
    }

    // MARK: - 评分条

    private var ratingBar: some View {
        VStack(spacing: Space.m) {
            HStack(spacing: Space.m) {
                ratingButton("不认识", rating: .again, color: .red, symbol: "xmark")
                ratingButton("有点难", rating: .hard, color: .orange, symbol: "minus")
                ratingButton("认识", rating: .good, color: .green, symbol: "checkmark")
                ratingButton("很熟", rating: .easy, color: .blue, symbol: "star.fill")
            }
            .opacity(vm.canRate ? 1 : 0.42)
            .animation(.easeInOut(duration: 0.18), value: vm.canRate)

            HStack(spacing: Space.l) {
                if !vm.isFront && !vm.hasRatedCurrent {
                    Button("跳过这张") { vm.skip() }
                        .buttonStyle(.plain)
                        .font(Type.caption)
                        .foregroundStyle(Ink.secondary)
                        .keyboardShortcut("s", modifiers: [])
                        .help("不评分、不改调度，直接看下一张")
                }
                Text(vm.isFront ? "翻开后按 1–4 评分" : "剩余 \(vm.remaining) 张")
                    .font(Type.caption)
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }

    private func ratingButton(
        _ title: String, rating: Rating, color: Color, symbol: String
    ) -> some View {
        Button {
            vm.rate(rating)
        } label: {
            VStack(spacing: Space.xxs) {
                Image(systemName: symbol).font(Type.reading)
                Text(title).font(Type.caption)
                Text(keyLabel(rating))
                    .font(Type.micro)
                    .foregroundStyle(Ink.tertiary)
            }
            .frame(width: Size.ratingButtonW, height: Size.ratingButtonH)
            .background(color.opacity(vm.canRate ? 0.14 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(color.opacity(vm.canRate ? 0.38 : 0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // @ai: 未翻开时禁用——`.disabled` 会连快捷键一起废掉，这正是我们要的
        //      （避免「盲评跳过整张卡」）。图标仍是灰的，用户能看出「还得先翻开」。
        .disabled(!vm.canRate)
        .keyboardShortcut(keyForRating(rating), modifiers: [])
        .help("\(title)（\(keyLabel(rating))）")
    }

    private func keyForRating(_ rating: Rating) -> KeyEquivalent {
        KeyEquivalent(Character(keyLabel(rating)))
    }

    /// 快捷键与按钮上的数字标签同源，禁止各写一份（旧实现两个 switch 各写一遍）。
    private func keyLabel(_ rating: Rating) -> String {
        String(rating.rawValue)
    }

    private func stateColor(_ belief: Double?) -> Color {
        WordMarkState.from(belief: belief, mastery: nil, seenCount: 0).color
    }

    // MARK: - 空状态

    /// 空状态分三种，分别给「下一步」——旧实现一律显示「今天的复习完成！」，
    /// 词库为空时也这么说，用户会以为坏了。
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Space.l) {
            switch vm.emptyReason {
            case .noCards:
                Image(systemName: "tray")
                    .font(IconSize.hero)
                    .foregroundStyle(Ink.secondary)
                Text("还没有可背的卡片").font(Type.title)
                Text("去「词库」导入一个词书（Anki .apkg 或 CSV），卡片会出现在这里。")
                    .font(Type.caption)
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
            case .roundFinished(let dueNow):
                Image(systemName: "checkmark.circle")
                    .font(IconSize.hero)
                    .foregroundStyle(.green)
                Text("本轮 \(vm.completedInRound) 张，背完了").font(Type.title)
                Text("还有 \(dueNow) 张到期卡，刷新队列可以继续。")
                    .font(Type.caption)
                    .foregroundStyle(Ink.secondary)
                Button("继续下一轮") { vm.reload() }
                    .padding(.top, Space.xs)
            case .clearedToday:
                Image(systemName: "checkmark.circle")
                    .font(IconSize.hero)
                    .foregroundStyle(.green)
                Text("今天的复习完成").font(Type.title)
                Text("到期卡片已清空。去「创作」生成文章，或等明天的新卡。")
                    .font(Type.caption)
                    .foregroundStyle(Ink.secondary)
                Text("已确认会、或模型高置信的词会自动跳过背诵队列。")
                    .font(Type.micro)
                    .foregroundStyle(Ink.tertiary)
            }
        }
        // @ai: 页面级留白由外层 `PageBody` 统一给（`Space.page`），这里不再叠
        //      `.padding(Space.xxl)`——两层叠加会变成 48pt，与其他页面对不齐。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
