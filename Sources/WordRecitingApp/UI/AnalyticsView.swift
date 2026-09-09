import SwiftUI

/// 分析视图：掌握度 / 词汇量画像 / 记忆质量 / 学习行为 / 复习统计。
/// @ai: UI 不写 SQL；查询走 vm.reload → GraphQueries。图表只走 `UI/Charts` 的组件。
struct AnalyticsView: View {
    @State private var vm: AnalyticsViewModel
    @State private var heatmapMode: HeatmapMode = .reviews

    init(world: World) {
        _vm = State(initialValue: AnalyticsViewModel(world: world))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { vm.reload() }
    }

    private var header: some View {
        HStack {
            Text("学习数据").font(.headline)
            Spacer()
            Button { vm.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let err = vm.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                abilitySection
                Divider()
                profileSection
                Divider()
                memoryQualitySection
                Divider()
                behaviorSection
                Divider()
                forecastSection
                Divider()
                reviewSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 掌握度分布（BKT 后验概率档位）

    @ViewBuilder
    private var abilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("掌握度分布").font(.headline)
                Text("BKT 后验概率档位（≥\(MasteryPresentation.percentText(WordMarkState.knownThreshold)) 会 · ≤\(MasteryPresentation.percentText(WordMarkState.unknownThreshold)) 不会 · 中间学习中）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let d = vm.distribution, d.total > 0 {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                    alignment: .leading, spacing: 10
                ) {
                    statCard("已会", "\(d.known)", icon: "checkmark.circle.fill", tint: .green)
                    statCard("不会", "\(d.unknown)", icon: "xmark.circle.fill", tint: .red)
                    statCard("学习中", "\(d.learning)", icon: "circle.lefthalf.filled", tint: .orange)
                    statCard("无概率", "\(max(0, (vm.overview?.unmarked ?? 0)))",
                             icon: "circle", tint: .secondary)
                }
            } else {
                Text("还没有概率数据。先在「词汇」页初始化，或阅读 RSS 文章——事件积累后模型会给出概率。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("词汇量画像").font(.headline)
                Text("按 BNC/COCA 词族带估算").font(.caption).foregroundStyle(.tertiary)
            }
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
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
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
                    VStack(alignment: .leading, spacing: 8) {
                        AnalyticsBarChart(segments: vm.masteryTrend, stacked: true, height: 140)
                        ChartSeriesLegend(series: [.known, .learning, .unknown])
                    }
                }
            }
        }
    }

    /// CEFR 等级条（参考坐标，非硬标准）。
    private func cefrCard(_ progress: CEFRProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(progress.current?.label ?? "—")
                    .font(.system(size: 30, weight: .semibold))
                Text(progress.current?.title ?? "尚未达到 A1")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let next = progress.next {
                    Text("距 \(next.label) 还差约 \(Int(progress.remainingFamilies.rounded())) 个词族")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("已达最高等级").font(.caption).foregroundStyle(.tertiary)
                }
            }
            AnalyticsLevelBar(segments: [
                LevelSegment(label: "进度", value: progress.progressToNext, tint: .accent)
            ], total: 1)
            Text("CEFR 参照：A1≈500 / A2≈1.5k / B1≈2.5k / B2≈4.5k / C1≈8k / C2≈10k 词族（参考坐标，非硬标准）")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func estimateRow(_ p: VocabularyProfile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(Int(p.estimatedKnownTotal.rounded()))")
                .font(.system(size: 34, weight: .semibold))
                .monospacedDigit()
            Text("个词族（估算）").font(.callout).foregroundStyle(.secondary)
            if p.totalFamilies > 0 {
                Text(String(format: "约占词表 %.1f%%",
                            p.estimatedKnownTotal / Double(p.totalFamilies) * 100))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func bandChart(_ p: VocabularyProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(p.bands) { band in
                HStack(spacing: 10) {
                    Text(FrequencyBandPresentation.bandLabel(band.band))
                        .font(.caption2).monospacedDigit()
                        .frame(width: 56, alignment: .leading)
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
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Text("已观测 \(band.observedFamilies)/\(band.totalFamilies)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(width: 110, alignment: .leading)
                }
            }
        }
    }

    private func coverageHint(_ p: VocabularyProfile) -> some View {
        let known = p.estimatedKnownTotal
        return VStack(alignment: .leading, spacing: 4) {
            Text("覆盖阈值参照（书面文本）").font(.caption.weight(.semibold))
            Text("95% 阅读覆盖 ≈ \(Self.coverage95Families) 词族 · 98% ≈ \(Self.coverage98Families) 词族")
                .font(.caption2).foregroundStyle(.secondary)
            Text(known >= Double(Self.coverage98Families)
                 ? "按当前估算已达到 98% 覆盖参照线"
                 : (known >= Double(Self.coverage95Families)
                    ? "按当前估算已达到 95% 覆盖参照线"
                    : "距 95% 覆盖参照线还差约 \(Int(Double(Self.coverage95Families) - known)) 个词族"))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var disclaimer: some View {
        Text("说明：估算 = 已观测词的后验概率之和 + 观测充分的词频带（≥\(VocabularyProfileBuilder.minObservedForExtrapolation) 个）按平滑认识率外推；观测不足的带只统计已观测词。\(vm.hasFrequencyTable ? "" : "当前未加载词频表，只统计已观测词。")词频带只是参考坐标，不作硬标准；概率是模型推断值，不是精确测量。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 记忆质量（二期）

    @ViewBuilder
    private var memoryQualitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("记忆质量").font(.headline)
                Text("回答「记牢了吗」——真实保留率、评分分布、经验遗忘曲线")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if vm.reviewRecords.isEmpty {
                Text("还没有复习数据。先背几个词，这里会出现保留率与遗忘曲线。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                          alignment: .leading, spacing: 12) {
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

    private var retentionCard: some View {
        ChartCard(title: "真实保留率",
                  subtitle: "通过 = 记得 / 简单 · 目标带 80–90%") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(vm.retention.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                    Text("共 \(vm.reviewRecords.count) 次评分")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                AnalyticsLineChart(points: vm.retentionTrend,
                                   targetBand: 0.8...0.9,
                                   valueFormat: { String(format: "%.0f%%", $0 * 100) },
                                   tint: .green, height: 130)
                Text("按日趋势；浅色带为 80–90% 目标区间")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var ratingCard: some View {
        ChartCard(title: "评分分布", subtitle: "固定四档（again / hard / good / easy）") {
            VStack(spacing: 6) {
                ForEach(vm.ratingDistribution) { slice in
                    HStack(spacing: 10) {
                        Text(slice.label)
                            .font(.caption2)
                            .frame(width: 48, alignment: .leading)
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
                            .font(.caption2.weight(.semibold)).monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
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
                VStack(spacing: 6) {
                    ForEach(rows) { w in weakRow(w) }
                }
            }
        }
    }

    // MARK: - 学习行为（二期）

    @ViewBuilder
    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("学习行为").font(.headline)
                Text("回答「学得勤吗」——日历热力图、连续天数、复习量与时段分布")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if vm.dailyStats.isEmpty {
                Text("还没有学习记录。").font(.caption).foregroundStyle(.secondary)
            } else {
                heatmapCard
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    volumeCard
                    hourCard
                }
            }
        }
    }

    private var heatmapCard: some View {
        ChartCard(title: "日历热力图",
                  subtitle: "\(vm.dailyStats.count) 天有记录 · 当前连续 \(vm.streak) 天") {
            VStack(alignment: .leading, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("负载预测").font(.headline)
                Text("回答「接下来有多忙」——复习队列内卡片的未来 30 天到期分布")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if vm.forecast.isEmpty {
                Text("还没有可预测的卡片。").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    statCard("今日负载", "\(vm.todayLoad)", icon: "clock.badge.exclamationmark",
                             tint: .accentColor)
                    statCard("峰值日", peakText, icon: "chart.line.uptrend.xyaxis",
                             tint: .orange)
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("复习统计").font(.headline)
                Text("卡片维度：与上面的词汇画像不是同一层级（这里是背诵调度数据）")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            statGrid
        }
    }

    // MARK: - 统计卡

    @ViewBuilder
    private var statGrid: some View {
        if let s = vm.stats {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                statCard("总词数", "\(s.totalCards)", icon: "rectangle.stack")
                statCard("已学", "\(s.studiedCards)", icon: "book.fill")
                statCard("今日到期", "\(s.dueCount)", icon: "clock")
                statCard("今日已复习", "\(s.reviewedToday)", icon: "checkmark.circle")
                statCard("总复习次数", "\(s.totalReviews)", icon: "repeat")
                statCard("AGAIN 率", String(format: "%.0f%%", s.againRatio * 100),
                         icon: "exclamationmark.triangle")
            }
        }
    }

    private func statCard(_ label: String, _ value: String, icon: String,
                          tint: Color = Color.accentColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5), lineWidth: 1))
    }

    // MARK: - 顽固词行

    private func weakRow(_ w: WeakLemmaStat) -> some View {
        HStack(spacing: 12) {
            Text(w.text)
                .font(.body.weight(.medium))
                .frame(width: 140, alignment: .leading)
            Text(FrequencyBandPresentation.bandLabel(vm.band(for: w)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(0.15))
                        Capsule()
                            .fill(w.againRatio > 0.5 ? Color.red : Color.orange)
                            .frame(width: geo.size.width * w.againRatio)
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(w.reviewCount) 次 · 不认识 \(w.againCount) 次")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", w.againRatio * 100))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(w.againRatio > 0.5 ? .red : .orange)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
