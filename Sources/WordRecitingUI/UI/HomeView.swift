import SwiftUI
import WordRecitingCore

/// 首页：一屏结论 + 入口。
/// @ai: 「首页给判断，分析页给依据」——这里只放能立刻做决定的数（今日负载 / 连续天数 /
///      今日保留率 / 词汇量档位），深度趋势与分布去分析页。
struct HomeView: View {
    @State private var vm: HomeViewModel
    private let onNavigate: (AppSection) -> Void

    init(world: World, onNavigate: @escaping (AppSection) -> Void) {
        _vm = State(initialValue: HomeViewModel(world: world))
        self.onNavigate = onNavigate
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let err = vm.errorMessage {
                    Text(err).font(Type.caption).foregroundStyle(.red)
                }
                if vm.isFirstRun { welcomeCard }
                todayHeader
                kpiRow
                vocabularyCard
                weakCard
                quickActions
            }
            .padding(Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { vm.reload() }
    }

    // MARK: - 新手引导

    /// 首次运行欢迎卡：三步走完就能用起来。
    /// @ai: 新用户打开 app 时首页只有一排 0，没有任何「下一步做什么」的提示。
    ///      这里给出最短可用路径：导词库 → 标词汇（可选）→ 开始。三处均可直达。
    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.m) {
                Image(systemName: "hand.wave.fill")
                    .foregroundStyle(Color.accentColor)
                Text("欢迎使用 wordincontxt")
                    .font(Type.section)
                Spacer()
            }
            Text("纯本地运行，不联网、不采集数据。三步开始：")
                .font(Type.caption)
                .foregroundStyle(Ink.secondary)

            VStack(alignment: .leading, spacing: Space.m) {
                welcomeStep(
                    "1", "导入一个词库",
                    "从 AnkiWeb 下载 .apkg，或用你自己的 CSV。也可以直接跳到第 3 步用内置词表。",
                    label: "去导入", section: .decks)
                welcomeStep(
                    "2", "（可选）让我了解你的词汇量",
                    "生成一段英文，标出不会的词，其余记为已掌握——后续选词会更贴合你。",
                    label: "去标记", section: .vocabulary)
                welcomeStep(
                    "3", "开始背或开始创作",
                    "有词库后可背诵闪卡；也可以直接选词生成一段上下文文章来读。",
                    label: "去背诵", section: .study)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
    }

    private func welcomeStep(
        _ number: String, _ title: String, _ detail: String,
        label: String, section: AppSection
    ) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: Size.iconTiny, height: Size.iconTiny)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(Type.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            DButton(label, rank: .quiet) { onNavigate(section) }
        }
    }

    // MARK: - 今日

    private var todayHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("今天 · \(Date().formatted(.dateTime.year().month().day().weekday(.wide)))")
                .font(Type.section)
            Spacer()
            IconButton(icon: "arrow.clockwise", help: "刷新") { vm.reload() }
        }
    }

    private var kpiRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: GridMetrics.kpiMin),
                                     spacing: Space.m)],
                  alignment: .leading, spacing: Space.m) {
            StatTile(label: "今日到期", value: "\(vm.stats?.dueCount ?? 0)",
                     icon: "clock", tint: .accentColor, emphasis: true)
            StatTile(label: "今日已复习", value: "\(vm.stats?.reviewedToday ?? 0)",
                     icon: "checkmark.circle", tint: .green, emphasis: true)
            StatTile(label: "连续天数", value: "\(vm.streak)",
                     icon: "flame.fill", tint: .orange, emphasis: true)
            StatTile(label: "今日保留率", value: retentionText,
                     icon: "target", tint: .blue, emphasis: true)
        }
    }

    private var retentionText: String {
        guard let value = vm.todayRetention else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    // MARK: - 词汇量

    @ViewBuilder
    private var vocabularyCard: some View {
        if let d = vm.distribution, d.total > 0 {
            ChartCard(title: "词汇量",
                      subtitle: "BKT 后验概率档位 · 估算按词频带外推") {
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Text("\(d.known)")
                            .font(Type.display)
                            .monospacedDigit()
                        Text("个词已会").font(Type.caption).foregroundStyle(Ink.secondary)
                        if let level = vm.cefr?.current {
                            Text("· \(level.label) \(level.title)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Ink.secondary)
                        }
                        if let p = vm.profile {
                            Text("· 估算 \(Int(p.estimatedKnownTotal.rounded())) 个词族")
                                .font(Type.caption).foregroundStyle(Ink.tertiary)
                        }
                        Spacer()
                    }
                    AnalyticsLevelBar(segments: [
                        LevelSegment(label: "已会", value: Double(d.known), tint: .green),
                        LevelSegment(label: "学习中", value: Double(d.learning), tint: .orange),
                        LevelSegment(label: "不会", value: Double(d.unknown), tint: .red)
                    ], total: Double(d.total))
                    HStack {
                        ChartSeriesLegend(series: [.known, .learning, .unknown])
                        Spacer()
                        Text("共 \(d.total) 个有概率的词")
                            .font(Type.micro).foregroundStyle(Ink.tertiary)
                    }
                    if vm.knownTrend.count >= 2 {
                        AnalyticsSparkline(points: vm.knownTrend, tint: .green, height: 32)
                        Text("已会词数趋势（最近 \(vm.knownTrend.count) 天）")
                            .font(Type.micro).foregroundStyle(Ink.tertiary)
                    }
                }
            }
        } else {
            ChartCard(title: "词汇量", subtitle: "还没有概率数据") {
                ChartEmptyState(text: "先在「词汇」页初始化，或读一篇 RSS 文章——事件积累后模型会给出概率。")
            }
        }
    }

    // MARK: - 薄弱词

    @ViewBuilder
    private var weakCard: some View {
        if !vm.weakLemmas.isEmpty {
            ChartCard(title: "薄弱词", subtitle: "按不认识比例降序，优先复习") {
                VStack(spacing: Space.s) {
                    ForEach(vm.weakLemmas) { w in
                        HStack(spacing: Space.l) {
                            Text(w.text).font(.body.weight(.medium))
                                .frame(width: Size.colWord, alignment: .leading)
                            Text("\(w.reviewCount) 次 · 不认识 \(w.againCount) 次")
                                .font(Type.micro).foregroundStyle(Ink.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", w.againRatio * 100))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(w.againRatio > 0.5 ? .red : .orange)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 快捷入口

    private var quickActions: some View {
        HStack(spacing: Space.m) {
            actionButton("开始背诵", icon: "book.fill", section: .study)
            actionButton("阅读文章", icon: "book.closed", section: .reading)
            actionButton("创作", icon: "square.and.pencil", section: .creation)
            Spacer()
        }
    }

    private func actionButton(_ title: String, icon: String, section: AppSection) -> some View {
        DButton(title, rank: .primary, icon: icon) {
            onNavigate(section)
        }
    }
}
