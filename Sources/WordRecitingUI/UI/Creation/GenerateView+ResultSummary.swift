import SwiftUI
import WordRecitingCore

// MARK: - 造文页 列4 生成过程：结果摘要（目标词覆盖 / 策略决策链 / 写作计划）

extension GenerateView {

    /// 生成结果摘要：目标词覆盖（哪些成功加入/哪些没有）+ 思维链（策略决策 + 写作计划展示）。
    var resultSummary: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !vm.coverage.isEmpty {
                HStack(spacing: Space.s) {
                    Text("目标词覆盖").font(Type.caption).foregroundStyle(Ink.secondary)
                    Text("\(vm.coverage.filter(\.hit).count)/\(vm.coverage.count)")
                        .font(Type.captionEmphasis)
                        .foregroundStyle(vm.coverage.allSatisfy(\.hit) ? .green : .orange)
                }
                // 词多时折叠（默认显示前 24 个 + 「更多」），避免上百目标词把列4撑爆
                let byWord = vm.coverage.reduce(into: [String: WordCoverage]()) { $0[$1.word] = $1 }
                ChipWall(words: vm.coverage.map(\.word), maxVisible: 24, minWidth: 70) { w in
                    let c = byWord[w]
                    HStack(spacing: Space.xxs) {
                        Image(systemName: (c?.hit ?? false) ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle((c?.hit ?? false) ? Color.green : Color.red)
                        Text(w).font(Type.caption)
                            .help(vm.skippedReason(for: w) ?? "未嵌入正文")
                    }
                    .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                    .background((c?.hit ?? false) ? Color.green.opacity(0.10) : Color.red.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
            if vm.lastStrategy != nil {
                DisclosureGroup("生成策略（模型决策链）") {
                    strategyChain
                }
                .font(Type.caption)
            }
            if let plan = vm.lastPlan, !plan.isEmpty {
                DisclosureGroup("写作计划（模型先联想并打草稿）") {
                    ScrollView {
                        Text(plan)
                            .font(Type.caption)
                            .foregroundStyle(Ink.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)   // 限制高度防撑高窗口，内部滚动
                }
                .font(Type.caption)
            }
        }
        .padding(.horizontal, Space.xxs)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 策略决策链：生成方式 / 改写窗口 / 嵌入兜底（模型三行决策的可读展示）。
    private var strategyChain: some View {
        HStack(spacing: Space.m) {
            if let s = vm.lastStrategy {
                strategyChip("生成方式", s.mode.label)
                strategyChip("改写窗口", s.window.label)
                strategyChip("嵌入兜底", s.fallback.label)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func strategyChip(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(name).font(Type.micro).foregroundStyle(Ink.tertiary)
            Text(value).font(Type.captionMedium)
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
    }
}
