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
                profileSection
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
                bandChart(p)
                coverageHint(p)
                disclaimer
            } else {
                Text("还没有可估算的数据。事件积累后这里会按词频带给出词汇量估算。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
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
        Text("说明：估算 = 已观测词的后验概率之和 + 未观测词按词频先验外推。\(vm.hasFrequencyTable ? "" : "当前未加载词频表，只统计已观测词。")词频带只是参考坐标，不作硬标准；概率是模型推断值，不是精确测量。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
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
