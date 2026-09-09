import SwiftUI

/// 词事件时间线（最近若干条）。
struct EventTimelineView: View {
    let items: [EventTimelineItem]
    var emptyText = "还没有事件记录"

    var body: some View {
        if items.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: EventTimelineItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.isActive ? "hand.tap" : "eye")
                .font(.caption2)
                .foregroundStyle(item.isActive ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            Text(item.kindLabel).font(.caption)
            Text(item.regionLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(item.trustLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Spacer()
            Text(item.timeText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}
