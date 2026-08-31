import SwiftUI

// MARK: - 造文页 列4 生成过程：结果摘要（目标词覆盖 / 策略决策链 / 写作计划）

extension GenerateView {

    /// 生成结果摘要：目标词覆盖（哪些成功加入/哪些没有）+ 思维链（策略决策 + 写作计划展示）。
    var resultSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !vm.coverage.isEmpty {
                HStack(spacing: 6) {
                    Text("目标词覆盖").font(.caption).foregroundStyle(.secondary)
                    Text("\(vm.coverage.filter(\.hit).count)/\(vm.coverage.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.coverage.allSatisfy(\.hit) ? .green : .orange)
                }
                // 词多时折叠（默认显示前 24 个 + 「更多」），避免上百目标词把列4撑爆
                let byWord = vm.coverage.reduce(into: [String: WordCoverage]()) { $0[$1.word] = $1 }
                ChipWall(words: vm.coverage.map(\.word), maxVisible: 24, minWidth: 70) { w in
                    let c = byWord[w]
                    HStack(spacing: 3) {
                        Image(systemName: (c?.hit ?? false) ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle((c?.hit ?? false) ? Color.green : Color.red)
                        Text(w).font(.caption)
                            .help(vm.skippedReason(for: w) ?? "未嵌入正文")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((c?.hit ?? false) ? Color.green.opacity(0.10) : Color.red.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
            if vm.lastStrategy != nil {
                DisclosureGroup("生成策略（模型决策链）") {
                    strategyChain
                }
                .font(.caption)
            }
            if let plan = vm.lastPlan, !plan.isEmpty {
                DisclosureGroup("写作计划（模型先联想并打草稿）") {
                    ScrollView {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)   // 限制高度防撑高窗口，内部滚动
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 策略决策链：生成方式 / 改写窗口 / 嵌入兜底（模型三行决策的可读展示）。
    private var strategyChain: some View {
        HStack(spacing: 8) {
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
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
