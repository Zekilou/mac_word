import SwiftUI

/// 生成过程可视化：思考日志 + 实时指标 + 当前阶段（模型自标记优先）。
struct GenThinkingLogView: View {
    let log: [ThinkingLogItem]
    let stats: StreamStats
    /// 模型自报的当前阶段（THINKING 标记行）；nil 时回退 fallbackStage。
    let modelStage: String?
    /// 管线阶段的兜底标签（模型未自报时展示）。
    let fallbackStage: String
    let isGenerating: Bool
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("⏱ 生成过程").font(.caption.weight(.semibold))
                Spacer()
                if isGenerating {
                    Button(role: .destructive) { onStop() } label: {
                        Label("停止", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if isGenerating {
                currentStageRow
            }
            if log.isEmpty {
                Text("正在启动…")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(log) { item in
                                logRow(item)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 260)
                    .onChange(of: log.count) { _, _ in
                        withAnimation { proxy.scrollTo(log.last?.id, anchor: .bottom) }
                    }
                }
            }
            metricsRow
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 当前阶段：优先模型自己的 THINKING 标记，无则回退管线阶段（醒目标识，等的人一眼看到模型在干嘛）。
    private var currentStageRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("当前阶段（模型自报）").font(.caption2).foregroundStyle(.tertiary)
                Text(modelStage ?? fallbackStage)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(modelStage == nil ? Color.primary : Color.accentColor)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func logRow(_ item: ThinkingLogItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(icon(item.kind)).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(statusSymbol(item.status)).font(.caption2)
                    Text(item.message)
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? Color.red : Color.primary)
                }
                if let detail = item.detail, !detail.isEmpty {
                    DisclosureGroup("详情") {
                        ScrollView {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)   // 限制高度防撑高窗口
                    }
                    .font(.caption2)
                }
            }
            Spacer(minLength: 4)
            Text(String(format: "%.1fs", item.elapsedAt))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// 实时指标行：首 token / 速率 / token 数。
    private var metricsRow: some View {
        HStack(spacing: 10) {
            metric("首token",
                   stats.firstTokenLatency.map { String(format: "%.1fs", $0) } ?? "—")
            metric("速率", stats.tokens > 0 ? String(format: "%.1f tok/s", stats.rate) : "—")
            metric("tokens", "\(stats.tokens)")
            Spacer()
        }
        .font(.caption2)
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func icon(_ kind: GenThought.Kind) -> String {
        switch kind {
        case .strategy: return "🧭"
        case .planning: return "✏️"
        case .generating: return "📝"
        case .embedding: return "🎯"
        case .polishing: return "✨"
        case .saving: return "💾"
        case .info: return "ℹ️"
        }
    }

    private func statusSymbol(_ status: GenThought.Status) -> String {
        switch status {
        case .running: return "⟳"
        case .done: return "✓"
        case .failed: return "✗"
        }
    }
}
