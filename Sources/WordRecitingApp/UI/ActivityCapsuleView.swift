import SwiftUI

/// 全局状态胶囊：窗口左下角圆角矩形卡片，宽度 = 一级折叠宽度(48) + 二级导航栏宽度(140)
/// = 188 为上限，与左侧导航总宽对齐；多个任务竖向堆叠；无任务时**不显示**。
/// @ai: 只读 GlobalActivityCenter.shared；自身不注册活动；无任务自动隐藏。
///      文字溢出时 MarqueeText 水平滚动；点击某行弹 popover 显示详细面板（运行时长 + 取消按钮）。
struct ActivityCapsuleView: View {
    let center: GlobalActivityCenter

    var body: some View {
        if !center.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(center.items) { item in
                    itemRow(item)
                }
            }
            .padding(8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
            .frame(width: 184)   // 184 < 188（一级折叠 48 + 二级 140），不遮挡内容区
        }
    }

    /// 每项一行：图标 + 标题 + 进度（线性或 mini 旋转）+ 消息（可选）。
    /// 点击展开 popover 详细面板；MarqueeText 处理文字溢出滚动。
    private func itemRow(_ item: GlobalActivityCenter.Item) -> some View {
        HStack(spacing: 6) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            MarqueeText(text: item.title, font: .caption, color: .primary)
                .frame(width: 56)
            if let p = item.progress {
                ProgressView(value: min(max(p, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(width: 56)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            if let msg = item.message {
                MarqueeText(text: msg, font: .caption2, color: .secondary)
                    .frame(width: 48)
            }
        }
        .contentShape(Rectangle())
        .help("点击查看详情")
        .popover(isPresented: popoverBinding(for: item.id), arrowEdge: .leading) {
            ActivityDetailPopover(item: item, center: center)
        }
        .onTapGesture { expandedID = item.id }
    }

    // MARK: - popover 状态（本地 @State）

    @State private var expandedID: UUID?

    private func popoverBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedID == id },
            set: { newValue in if !newValue { expandedID = nil } }
        )
    }
}

/// 详细面板 popover：完整标题 + 进度数值 + 字节进度 + 运行时长 + 取消按钮。
/// @ai: 独立小 View 控制行数；运行时长用 TimelineView 每秒刷新。
private struct ActivityDetailPopover: View {
    let item: GlobalActivityCenter.Item
    let center: GlobalActivityCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack(spacing: 6) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                }
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
            }

            Divider()

            // 进度数值
            if let p = item.progress {
                detailRow(label: "进度", value: percentText(p))
                ProgressView(value: min(max(p, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            } else {
                detailRow(label: "进度", value: "不确定")
            }

            // 消息
            if let msg = item.message {
                detailRow(label: "状态", value: msg)
            }

            // 字节进度
            if let bytes = item.bytes {
                detailRow(label: "已下载", value: byteText(bytes.received))
                detailRow(label: "总大小", value: byteText(bytes.total))
                let speed = bytes.total > 0 ? Double(bytes.received) / Double(bytes.total) : 0
                detailRow(label: "完成比", value: percentText(speed))
            }

            // tag
            if let tag = item.tag {
                detailRow(label: "标签", value: tag)
            }

            // 运行时长（每秒刷新）
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                detailRow(label: "运行时长", value: durationText(since: item.startedAt))
            }

            // 取消按钮（始终显示，调用 center.cancel）
            HStack {
                Spacer()
                Button(role: .destructive) {
                    center.cancel(item.id)
                } label: {
                    Label("取消任务", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - 格式化

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percentText(_ p: Double) -> String {
        let v = max(0, min(1, p))
        return String(format: "%.1f%%", v * 100)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func durationText(since start: Date) -> String {
        let interval = max(0, Date.now.timeIntervalSince(start))
        if interval < 60 {
            return "\(Int(interval)) 秒"
        } else if interval < 3600 {
            let m = Int(interval / 60)
            let s = Int(interval) % 60
            return "\(m) 分 \(s) 秒"
        } else {
            let h = Int(interval / 3600)
            let m = (Int(interval) % 3600) / 60
            return "\(h) 时 \(m) 分"
        }
    }
}
