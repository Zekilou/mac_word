import SwiftUI
import WordRecitingCore

/// 词事件时间线（最近若干条）。
struct EventTimelineView: View {
    let items: [EventTimelineItem]
    var emptyText = "还没有事件记录"

    var body: some View {
        if items.isEmpty {
            Text(emptyText)
                .font(Type.caption)
                .foregroundStyle(Ink.secondary)
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: EventTimelineItem) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: item.isActive ? "hand.tap" : "eye")
                .font(Type.micro)
                .foregroundStyle(item.isActive ? Color.accentColor : Color.secondary)
                .frame(width: Size.capsulePadding)
            Text(item.kindLabel).font(Type.caption)
            Text(item.regionLabel)
                .font(Type.micro)
                .foregroundStyle(Ink.secondary)
            Text(item.trustLabel)
                .font(Type.micro)
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, Space.xs)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
            Spacer()
            Text(item.timeText)
                .font(Type.micro)
                .foregroundStyle(Ink.tertiary)
                .monospacedDigit()
        }
    }
}
