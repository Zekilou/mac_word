import Foundation

/// 事件时间线的展示模型。
struct EventTimelineItem: Sendable, Equatable, Identifiable {
    var id: EntityID { eventId }
    let eventId: EntityID
    /// 事件种类中文（未知 rawValue 原样显示）。
    let kindLabel: String
    /// 来源上下文中文。
    let regionLabel: String
    /// "主动" / "被动"。
    let trustLabel: String
    /// 是否高可信（trust ≥ 0.5）。
    let isActive: Bool
    let occurredAt: Date
    /// 相对时间文案。
    let timeText: String
}

/// 词事件 → 时间线展示模型（纯函数，可单测）。
enum EventTimelinePresenter {

    static func kindLabel(_ kind: WordEventKind) -> String {
        switch kind {
        case .seen: return "出现过"
        case .lookup: return "查词"
        case .markKnown: return "标记会"
        case .markUnknown: return "标记不会"
        case .quizCorrect: return "答对"
        case .quizWrong: return "答错"
        }
    }

    static func regionLabel(_ kind: String) -> String {
        guard let kind = RegionKind(rawValue: kind) else { return "其他" }
        switch kind {
        case .study: return "复习"
        case .rss: return "RSS 阅读"
        case .generate: return "生成文章"
        case .dictionary: return "词典"
        case .initSession: return "词汇初始化"
        }
    }

    /// - Parameter regionKinds: region id → RegionKind.rawValue（调用方批量查好）。
    static func items(from rows: [GraphQueries.WordEventRow],
                      regionKinds: [EntityID: String] = [:],
                      now: Date = Date()) -> [EventTimelineItem] {
        rows.map { row in
            let kind = WordEventKind(rawValue: row.kind)
            let active = row.trust >= 0.5
            return EventTimelineItem(
                eventId: row.eventId,
                kindLabel: kind.map(kindLabel) ?? row.kind,
                regionLabel: regionLabel(regionKinds[row.regionId] ?? ""),
                trustLabel: active ? "主动" : "被动",
                isActive: active,
                occurredAt: row.occurredAt,
                timeText: relativeText(from: row.occurredAt, now: now))
        }
    }

    static func relativeText(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds < 86400 * 30 { return "\(Int(seconds / 86400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
