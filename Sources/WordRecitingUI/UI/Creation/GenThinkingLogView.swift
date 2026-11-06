import SwiftUI
import WordRecitingCore

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
        Panel(padding: Space.m) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.m) {
                    Text("⏱ 生成过程").font(.caption.weight(.semibold))
                    Spacer()
                    if isGenerating {
                        // 原 Button(role: .destructive) + .bordered：用 destructive 档保留红字语义
                        DButton("停止", rank: .destructive, icon: "stop.circle") {
                            onStop()
                        }
                    }
                }
                if isGenerating {
                    currentStageRow
                }
                if log.isEmpty {
                    Text("正在启动…")
                        .font(Type.caption).foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.rowV)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Space.xxs) {
                                ForEach(log) { item in
                                    logRow(item)
                                }
                            }
                            .padding(.vertical, Space.xs)
                        }
                        .frame(height: 260)
                        .onChange(of: log.count) { _, _ in
                            withAnimation { proxy.scrollTo(log.last?.id, anchor: .bottom) }
                        }
                    }
                }
                metricsRow
            }
        }
    }

    /// 当前阶段：优先模型自己的 THINKING 标记，无则回退管线阶段（醒目标识，等的人一眼看到模型在干嘛）。
    private var currentStageRow: some View {
        HStack(spacing: Space.m) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("当前阶段（模型自报）").font(Type.micro).foregroundStyle(Ink.tertiary)
                Text(modelStage ?? fallbackStage)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(modelStage == nil ? Color.primary : Color.accentColor)
            }
            Spacer()
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
    }

    private func logRow(_ item: ThinkingLogItem) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Text(icon(item.kind)).font(Type.caption)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(statusSymbol(item.status)).font(Type.micro)
                    Text(item.message)
                        .font(Type.caption)
                        .foregroundStyle(item.status == .failed ? Color.red : Color.primary)
                }
                if let detail = item.detail, !detail.isEmpty {
                    DisclosureGroup("详情") {
                        ScrollView {
                            Text(detail)
                                .font(Type.micro)
                                .foregroundStyle(Ink.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)   // 限制高度防撑高窗口
                    }
                    .font(Type.micro)
                }
            }
            Spacer(minLength: 4)
            Text(String(format: "%.1fs", item.elapsedAt))
                .font(Type.micro).foregroundStyle(Ink.tertiary)
        }
        .padding(.vertical, Space.xxs)
    }

    /// 实时指标行：首 token / 速率 / token 数。
    private var metricsRow: some View {
        HStack(spacing: Space.m) {
            metric("首token",
                   stats.firstTokenLatency.map { String(format: "%.1fs", $0) } ?? "—")
            metric("速率", stats.tokens > 0 ? String(format: "%.1f tok/s", stats.rate) : "—")
            metric("tokens", "\(stats.tokens)")
            Spacer()
        }
        .font(Type.micro)
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).foregroundStyle(Ink.tertiary)
            Text(value).foregroundStyle(Ink.secondary)
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
