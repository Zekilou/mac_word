import SwiftUI

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
            VStack(alignment: .leading, spacing: 16) {
                if let err = vm.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                todayHeader
                kpiRow
                vocabularyCard
                weakCard
                quickActions
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { vm.reload() }
    }

    // MARK: - 今日

    private var todayHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("今天 · \(Date().formatted(.dateTime.year().month().day().weekday(.wide)))")
                .font(.headline)
            Spacer()
            Button { vm.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")
        }
    }

    private var kpiRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            kpiCard("今日到期", "\(vm.stats?.dueCount ?? 0)",
                    icon: "clock", tint: .accentColor)
            kpiCard("今日已复习", "\(vm.stats?.reviewedToday ?? 0)",
                    icon: "checkmark.circle", tint: .green)
            kpiCard("连续天数", "\(vm.streak)",
                    icon: "flame.fill", tint: .orange)
            kpiCard("今日保留率", retentionText,
                    icon: "target", tint: .blue)
        }
    }

    private var retentionText: String {
        guard let value = vm.todayRetention else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private func kpiCard(_ label: String, _ value: String, icon: String,
                         tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5), lineWidth: 1))
    }

    // MARK: - 词汇量

    @ViewBuilder
    private var vocabularyCard: some View {
        if let d = vm.distribution, d.total > 0 {
            ChartCard(title: "词汇量",
                      subtitle: "BKT 后验概率档位 · 估算按词频带外推") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(d.known)")
                            .font(.system(size: 34, weight: .semibold))
                            .monospacedDigit()
                        Text("个词已会").font(.callout).foregroundStyle(.secondary)
                        if let p = vm.profile {
                            Text("· 估算 \(Int(p.estimatedKnownTotal.rounded())) 个词族")
                                .font(.caption).foregroundStyle(.tertiary)
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
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if vm.knownTrend.count >= 2 {
                        AnalyticsSparkline(points: vm.knownTrend, tint: .green, height: 32)
                        Text("已会词数趋势（最近 \(vm.knownTrend.count) 天）")
                            .font(.caption2).foregroundStyle(.tertiary)
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
                VStack(spacing: 6) {
                    ForEach(vm.weakLemmas) { w in
                        HStack(spacing: 12) {
                            Text(w.text).font(.body.weight(.medium))
                                .frame(width: 140, alignment: .leading)
                            Text("\(w.reviewCount) 次 · 不认识 \(w.againCount) 次")
                                .font(.caption2).foregroundStyle(.secondary)
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
        HStack(spacing: 10) {
            actionButton("开始背诵", icon: "book.fill", section: .study)
            actionButton("阅读文章", icon: "book.closed", section: .reading)
            actionButton("创作", icon: "square.and.pencil", section: .creation)
            Spacer()
        }
    }

    private func actionButton(_ title: String, icon: String, section: AppSection) -> some View {
        Button {
            onNavigate(section)
        } label: {
            Label(title, systemImage: icon)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
    }
}
