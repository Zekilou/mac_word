import SwiftUI

/// 分析视图：学习统计卡 + 弱词排行。
/// @ai: UI 不写 SQL；查询走 vm.reload → GraphQueries。
struct AnalyticsView: View {
    @State private var vm: AnalyticsViewModel

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
                reviewSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 词汇能力（全局掌握度，与词汇页同一口径）

    @ViewBuilder
    private var abilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("词汇能力").font(.headline)
                Text("全局掌握度：会 ≥1.5 · 不会 1~1.5 · 出现过 = 仅 seen · 未标记").font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let o = vm.overview {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                    alignment: .leading, spacing: 10
                ) {
                    statCard("已会", "\(o.known)", icon: "checkmark.circle.fill", tint: .green)
                    statCard("不会", "\(o.unknown)", icon: "xmark.circle.fill", tint: .red)
                    statCard("出现过", "\(o.seen)", icon: "eye.fill", tint: .blue)
                    statCard("未标记", "\(o.unmarked)", icon: "circle", tint: .secondary)
                }
            } else {
                Text("还没有掌握度数据。先在「词汇」页初始化，或阅读 RSS 文章。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
    }

    // MARK: - 复习表现（词库卡片维度的背诵数据）

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("复习表现").font(.headline)
                Text("词库卡片维度的背诵数据").font(.caption).foregroundStyle(.tertiary)
            }
            statGrid
            weakSection
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

    // MARK: - 弱词排行

    private var weakSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("弱词排行").font(.headline)
                Text("按不认识比例降序").font(.caption).foregroundStyle(.tertiary)
            }
            if vm.weakLemmas.isEmpty {
                Text("还没有复习数据。先学几个词，再来这里看表现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(vm.weakLemmas) { w in
                        weakRow(w)
                    }
                }
            }
        }
    }

    private func weakRow(_ w: WeakLemmaStat) -> some View {
        HStack(spacing: 12) {
            Text(w.text)
                .font(.body.weight(.medium))
                .frame(width: 140, alignment: .leading)
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
