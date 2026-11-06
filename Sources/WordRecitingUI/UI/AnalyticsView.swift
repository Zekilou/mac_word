import SwiftUI
import WordRecitingCore

/// 分析视图：掌握度 / 词汇量画像 / 记忆质量 / 学习行为 / 复习统计。
/// @ai: UI 不写 SQL；查询走 vm.reload → GraphQueries。图表只走 `UI/Charts` 的组件。
struct AnalyticsView: View {
    @State private var vm: AnalyticsViewModel
    @State private var heatmapMode: HeatmapMode = .reviews

    init(world: World) {
        _vm = State(initialValue: AnalyticsViewModel(world: world))
    }

    /// @ai: 原来这里自己拼「header + Rule + ScrollView + .padding(Space.page)」，
    ///      header 的边距是 Space.toolbarH / toolbarV 的手写副本。
    ///      现在交给 `PageScaffold`：标题行进 `toolbar`，主体进 `content`，
    ///      滚动与页面级边距由骨架统一提供（不再有第二套页面 padding）。
    var body: some View {
        PageScaffold {
            Text("学习数据").font(Type.section)
            Spacer()
            IconButton(icon: "arrow.clockwise", help: "刷新") { vm.reload() }
        } content: {
            if let err = vm.errorMessage {
                InlineError(message: err)
            }
            abilitySection
            Rule()
            profileSection
            Rule()
            memoryQualitySection
            Rule()
            behaviorSection
            Rule()
            forecastSection
            Rule()
            reviewSection
        }
        .onAppear { vm.reload() }
    }

    // MARK: - 掌握度分布（BKT 后验概率档位）

    @ViewBuilder
    private var abilitySection: some View {
        Section(
            title: "掌握度分布",
            note: "BKT 后验概率档位（≥\(MasteryPresentation.percentText(WordMarkState.knownThreshold)) 会 · ≤\(MasteryPresentation.percentText(WordMarkState.unknownThreshold)) 不会 · 中间学习中）"
        ) {
            if let d = vm.distribution, d.total > 0 {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: GridMetrics.statMin),
                                       spacing: Space.m)],
                    alignment: .leading, spacing: Space.m
                ) {
                    StatTile(label: "已会", value: "\(d.known)",
                             icon: "checkmark.circle.fill", tint: .green)
                    StatTile(label: "不会", value: "\(d.unknown)",
                             icon: "xmark.circle.fill", tint: .red)
                    StatTile(label: "学习中", value: "\(d.learning)",
                             icon: "circle.lefthalf.filled", tint: .orange)
                    StatTile(label: "无概率", value: "\(max(0, (vm.overview?.unmarked ?? 0)))",
                             icon: "circle", tint: Ink.secondary)
                }
            } else {
                Text("还没有概率数据。先在「词汇」页初始化，或阅读 RSS 文章——事件积累后模型会给出概率。")
                    .font(Type.caption).foregroundStyle(Ink.secondary).padding(.vertical, Space.xs)
            }
        }
    }

    // MARK: - 词汇量画像（估算）

    /// 覆盖阈值参照：书面文本 95% ≈ 4,000 词族、98% ≈ 8,000–9,000 词族
    /// （Laufer 1989 / Hu & Nation 2000；Kremmel & Schmitt 2023 指出 98% 并非对所有人可靠）。
    private static let coverage95Families = 4000
    private static let coverage98Families = 8500

    @ViewBuilder
    private var profileSection: some View {
        // @ai: 「词汇量画像」自己是一个带标题的正文块；下面两张趋势图是**各自独立的
        //      图表单元**（`ChartCard` 已自带 `Section` + `Card`）。所以标题只包住
        //      自己的估算内容，两张图表卡留在标题之外——否则会出现「标题套标题」。
        VStack(alignment: .leading, spacing: Space.l) {
            Section(title: "词汇量画像", note: "按 BNC/COCA 词族带估算") {
                VStack(alignment: .leading, spacing: Space.m) {
                    if let p = vm.profile, !p.bands.isEmpty {
                        estimateRow(p)
                        if let cefr = vm.cefr {
                            cefrCard(cefr)
                        }
                        bandChart(p)
                        coverageHint(p)
                        disclaimer
                    } else {
                        Text("还没有可估算的数据。事件积累后这里会按词频带给出词汇量估算。")
                            .font(Type.caption).foregroundStyle(Ink.secondary)
                            .padding(.vertical, Space.xs)
                    }
                }
            }
            if !vm.vocabularyTrend.isEmpty {
                ChartCard(title: "词汇量趋势", subtitle: "每日收盘估算（词族）") {
                    AnalyticsLineChart(points: vm.vocabularyTrend,
                                       valueFormat: { String(format: "%.0f", $0) },
                                       tint: .accent, height: 140)
                }
            }
            if !vm.masteryTrend.isEmpty {
                ChartCard(title: "掌握度分布趋势",
                          subtitle: "最近 \(min(vm.dailyStats.count, 30)) 天") {
                    VStack(alignment: .leading, spacing: Space.m) {
                        AnalyticsBarChart(segments: vm.masteryTrend, stacked: true, height: 140)
                        ChartSeriesLegend(series: [.known, .learning, .unknown])
                    }
                }
            }
        }
    }

    /// CEFR 等级条（参考坐标，非硬标准）。
    private func cefrCard(_ progress: CEFRProgress) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(progress.current?.label ?? "—")
                    .font(Type.displaySmall)
                Text(progress.current?.title ?? "尚未达到 A1")
                    .font(Type.caption).foregroundStyle(Ink.secondary)
                Spacer()
                if let next = progress.next {
                    Text("距 \(next.label) 还差约 \(Int(progress.remainingFamilies.rounded())) 个词族")
                        .font(Type.caption).foregroundStyle(Ink.tertiary)
                } else {
                    Text("已达最高等级").font(Type.caption).foregroundStyle(Ink.tertiary)
                }
            }
            AnalyticsLevelBar(segments: [
                LevelSegment(label: "进度", value: progress.progressToNext, tint: .accent)
            ], total: 1)
            Text("CEFR 参照：A1≈500 / A2≈1.5k / B1≈2.5k / B2≈4.5k / C1≈8k / C2≈10k 词族（参考坐标，非硬标准）")
                .font(Type.micro).foregroundStyle(Ink.tertiary)
        }
    }

    private func estimateRow(_ p: VocabularyProfile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text("\(Int(p.estimatedKnownTotal.rounded()))")
                .font(Type.display)
                .monospacedDigit()
            Text("个词族（估算）").font(Type.caption).foregroundStyle(Ink.secondary)
            if p.totalFamilies > 0 {
                Text(String(format: "约占词表 %.1f%%",
                            p.estimatedKnownTotal / Double(p.totalFamilies) * 100))
                    .font(Type.caption).foregroundStyle(Ink.tertiary)
            }
            Spacer()
        }
    }

    private func bandChart(_ p: VocabularyProfile) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(p.bands) { band in
                HStack(spacing: Space.m) {
                    Text(FrequencyBandPresentation.bandLabel(band.band))
                        .font(Type.micro).monospacedDigit()
                        .frame(width: Size.colBand, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.accentColor.opacity(0.12))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: geo.size.width * (band.coverage ?? 0))
                        }
                    }
                    .frame(height: 8)
                    Text(band.coverage.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        .font(Type.microEmphasis).monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                        .frame(width: Size.colPercent, alignment: .trailing)
                    Text("已观测 \(band.observedFamilies)/\(band.totalFamilies)")
                        .font(Type.micro).foregroundStyle(Ink.tertiary)
                        .frame(width: Size.fieldLabel, alignment: .leading)
                }
            }
        }
    }

    private func coverageHint(_ p: VocabularyProfile) -> some View {
        let known = p.estimatedKnownTotal
        return VStack(alignment: .leading, spacing: Space.xs) {
            Text("覆盖阈值参照（书面文本）").font(Type.captionEmphasis)
            Text("95% 阅读覆盖 ≈ \(Self.coverage95Families) 词族 · 98% ≈ \(Self.coverage98Families) 词族")
                .font(Type.micro).foregroundStyle(Ink.secondary)
            Text(known >= Double(Self.coverage98Families)
                 ? "按当前估算已达到 98% 覆盖参照线"
                 : (known >= Double(Self.coverage95Families)
                    ? "按当前估算已达到 95% 覆盖参照线"
                    : "距 95% 覆盖参照线还差约 \(Int(Double(Self.coverage95Families) - known)) 个词族"))
                .font(Type.micro).foregroundStyle(Ink.tertiary)
        }
    }

    private var disclaimer: some View {
        Text("说明：估算 = 已观测词的后验概率之和 + 观测充分的词频带（≥\(VocabularyProfileBuilder.minObservedForExtrapolation) 个）按平滑认识率外推；观测不足的带只统计已观测词。\(vm.hasFrequencyTable ? "" : "当前未加载词频表，只统计已观测词。")词频带只是参考坐标，不作硬标准；概率是模型推断值，不是精确测量。")
            .font(Type.micro)
            .foregroundStyle(Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 记忆质量（二期）

    @ViewBuilder
    private var memoryQualitySection: some View {
        Section(
            title: "记忆质量",
            note: "回答「记牢了吗」——真实保留率、评分分布、经验遗忘曲线"
        ) {
            if vm.reviewRecords.isEmpty {
                Text("还没有复习数据。先背几个词，这里会出现保留率与遗忘曲线。")
                    .font(Type.caption).foregroundStyle(Ink.secondary).padding(.vertical, Space.xs)
            } else {
                // 卡片网格与「顽固词」是两块独立图表单元，保持原来的 Space.l 节奏。
                VStack(alignment: .leading, spacing: Space.l) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: GridMetrics.chartMin), spacing: Space.l)],
                              alignment: .leading, spacing: Space.l) {
                        retentionCard
                        ratingCard
                        forgettingCurveCard
                        intervalCard
                        factorCard
                    }
                    leechCard
                }
            }
        }
    }

    private var retentionCard: some View {
        ChartCard(title: "真实保留率",
                  subtitle: "通过 = 记得 / 简单 · 目标带 80–90%") {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(vm.retention.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        .font(Type.displaySmall)
                        .monospacedDigit()
                    Text("共 \(vm.reviewRecords.count) 次评分")
                        .font(Type.caption).foregroundStyle(Ink.secondary)
                    Spacer()
                }
                AnalyticsLineChart(points: vm.retentionTrend,
                                   targetBand: 0.8...0.9,
                                   valueFormat: { String(format: "%.0f%%", $0 * 100) },
                                   tint: .green, height: 130)
                Text("按日趋势；浅色带为 80–90% 目标区间")
                    .font(Type.micro).foregroundStyle(Ink.tertiary)
            }
        }
    }

    private var ratingCard: some View {
        ChartCard(title: "评分分布", subtitle: "固定四档（again / hard / good / easy）") {
            VStack(spacing: Space.s) {
                ForEach(vm.ratingDistribution) { slice in
                    HStack(spacing: Space.m) {
                        Text(slice.label)
                            .font(Type.micro)
                            .frame(width: Size.colCount, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(slice.tint.color.opacity(0.15))
                                Capsule()
                                    .fill(slice.tint.color.opacity(0.8))
                                    .frame(width: geo.size.width * ratingRatio(slice.count))
                            }
                        }
                        .frame(height: 8)
                        Text("\(slice.count)")
                            .font(Type.microEmphasis).monospacedDigit()
                            .frame(width: Size.colNarrow, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func ratingRatio(_ count: Int) -> Double {
        let maxCount = vm.ratingDistribution.map(\.count).max() ?? 0
        return maxCount > 0 ? Double(count) / Double(maxCount) : 0
    }

    private var forgettingCurveCard: some View {
        ChartCard(title: "经验遗忘曲线",
                  subtitle: "按「距上次复习天数」分桶的保留率") {
            AnalyticsLineChart(points: vm.forgettingCurve,
                               valueFormat: { String(format: "%.0f%%", $0 * 100) },
                               tint: .orange, height: 130)
        }
    }

    private var intervalCard: some View {
        ChartCard(title: "复习间隔分布", subtitle: "卡片复习前所处的间隔天数") {
            AnalyticsHistogram(bins: vm.intervalBins,
                               xLabel: { String(format: "%.1f", $0.lowerBound) },
                               tint: .blue, height: 120)
        }
    }

    private var factorCard: some View {
        ChartCard(title: "难度因子分布", subtitle: "简化 SM-2 的 factor（越低越难）") {
            AnalyticsHistogram(bins: vm.factorBins,
                               xLabel: { String(format: "%.1f", $0.lowerBound) },
                               tint: .gray, height: 120)
        }
    }

    private var leechCard: some View {
        ChartCard(title: "顽固词", subtitle: "按平滑失败率 (again+1)/(次数+2) 降序") {
            let rows = Array(vm.weakLemmas
                .sorted { $0.smoothedFailureRate > $1.smoothedFailureRate }
                .prefix(5))
            if rows.isEmpty {
                ChartEmptyState()
            } else {
                VStack(spacing: Space.s) {
                    ForEach(rows) { w in weakRow(w) }
                }
            }
        }
    }

    // MARK: - 学习行为（二期）

    @ViewBuilder
    private var behaviorSection: some View {
        Section(
            title: "学习行为",
            note: "回答「学得勤吗」——日历热力图、连续天数、复习量与时段分布"
        ) {
            if vm.dailyStats.isEmpty {
                Text("还没有学习记录。").font(Type.caption).foregroundStyle(Ink.secondary)
            } else {
                // 热力图与两张图表卡是独立图表单元，保持原来的 Space.l 节奏。
                VStack(alignment: .leading, spacing: Space.l) {
                    heatmapCard
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: GridMetrics.chartMin), spacing: Space.l)],
                              alignment: .leading, spacing: Space.l) {
                        volumeCard
                        hourCard
                    }
                }
            }
        }
    }

    private var heatmapCard: some View {
        ChartCard(title: "日历热力图",
                  subtitle: "\(vm.dailyStats.count) 天有记录 · 当前连续 \(vm.streak) 天") {
            VStack(alignment: .leading, spacing: Space.m) {
                Picker("模式", selection: $heatmapMode) {
                    ForEach(HeatmapMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                AnalyticsHeatmap(cells: heatmapCells, weeks: heatmapWeeks,
                                 tint: heatmapTint,
                                 valueFormat: heatmapValueFormat)
            }
        }
    }

    private var heatmapWeeks: Int { 26 }

    private var heatmapCells: [HeatmapCell] {
        HeatmapBuilder.grid(
            values: BehaviorBuilder.heatmapValues(vm.dailyStats, mode: heatmapMode),
            endingOn: Date(), weeks: heatmapWeeks)
    }

    private var heatmapTint: ChartTint {
        switch heatmapMode {
        case .reviews: return .green
        case .newWords: return .blue
        case .retention: return .orange
        }
    }

    private var heatmapValueFormat: (Double) -> String {
        heatmapMode == .retention
            ? { String(format: "%.0f%%", $0) }
            : { String(format: "%.0f", $0) }
    }

    private var volumeCard: some View {
        ChartCard(title: "复习量", subtitle: "最近 \(vm.reviewVolume.count) 天") {
            AnalyticsSimpleBarChart(points: vm.reviewVolume, tint: .accent, height: 130)
        }
    }

    private var hourCard: some View {
        ChartCard(title: "时段分布", subtitle: "你通常在几点复习") {
            AnalyticsHistogram(bins: vm.hourBins,
                               xLabel: { String(format: "%02d", Int($0.lowerBound)) },
                               tint: .orange, height: 130)
        }
    }

    // MARK: - 负载预测（三期）

    @ViewBuilder
    private var forecastSection: some View {
        Section(
            title: "负载预测",
            note: "回答「接下来有多忙」——复习队列内卡片的未来 30 天到期分布"
        ) {
            if vm.forecast.isEmpty {
                Text("还没有可预测的卡片。").font(Type.caption).foregroundStyle(Ink.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: GridMetrics.kpiMin),
                                             spacing: Space.m)],
                          alignment: .leading, spacing: Space.m) {
                    StatTile(label: "今日负载", value: "\(vm.todayLoad)",
                             icon: "clock.badge.exclamationmark", tint: .accentColor)
                    StatTile(label: "峰值日", value: peakText,
                             icon: "chart.line.uptrend.xyaxis", tint: .orange)
                }
                ChartCard(title: "未来 30 天到期量",
                          subtitle: "第 1 天 = 今天（含已过期与新卡）") {
                    AnalyticsSimpleBarChart(points: ForecastBuilder.points(vm.forecast),
                                            tint: .accent, height: 150)
                }
            }
        }
    }

    private var peakText: String {
        guard let peak = vm.peakDay else { return "—" }
        return "\(peak.date) · \(peak.due)"
    }

    // MARK: - 复习表现（词库卡片维度的背诵数据）

    private var reviewSection: some View {
        Section(
            title: "复习统计",
            note: "卡片维度：与上面的词汇画像不是同一层级（这里是背诵调度数据）"
        ) {
            statGrid
        }
    }

    // MARK: - 统计卡

    @ViewBuilder
    private var statGrid: some View {
        if let s = vm.stats {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: GridMetrics.statMin),
                                   spacing: Space.m)],
                alignment: .leading, spacing: Space.m
            ) {
                StatTile(label: "总词数", value: "\(s.totalCards)", icon: "rectangle.stack")
                StatTile(label: "已学", value: "\(s.studiedCards)", icon: "book.fill")
                StatTile(label: "今日到期", value: "\(s.dueCount)", icon: "clock")
                StatTile(label: "今日已复习", value: "\(s.reviewedToday)",
                         icon: "checkmark.circle")
                StatTile(label: "总复习次数", value: "\(s.totalReviews)", icon: "repeat")
                StatTile(label: "AGAIN 率",
                         value: String(format: "%.0f%%", s.againRatio * 100),
                         icon: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - 顽固词行

    private func weakRow(_ w: WeakLemmaStat) -> some View {
        HStack(spacing: Space.l) {
            Text(w.text)
                .font(Type.emphasis)
                .frame(width: Size.colWord, alignment: .leading)
            Text(FrequencyBandPresentation.bandLabel(vm.band(for: w)))
                .font(Type.micro)
                .foregroundStyle(Ink.secondary)
                .frame(width: Size.colBand, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xs) {
                Meter(value: w.againRatio, tint: w.againRatio > 0.5 ? .red : .orange)
                HStack {
                    Text("\(w.reviewCount) 次 · 不认识 \(w.againCount) 次")
                        .font(Type.micro).foregroundStyle(Ink.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", w.againRatio * 100))
                        .font(Type.mono.weight(.semibold))
                        .foregroundStyle(w.againRatio > 0.5 ? .red : .orange)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Space.rowH)
        .padding(.vertical, Space.rowV)
        .background(Surface.card.opacity(0.5), in: .rect(cornerRadius: Radius.control))
    }
}
