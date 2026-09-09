import Foundation

/// 连续学习天数（纯函数）。
/// @ai: 判定「有活动」= 当天有词事件或复习评分；今天还没学习不算断签（从昨天起算）。
enum StreakCalculator {
    /// 截至 `endingOn` 的连续天数。
    static func current(_ stats: [DailyStat], endingOn: Date,
                        calendar: Calendar = .current) -> Int {
        let active = Set(stats.filter { $0.events > 0 || $0.reviews > 0 }.map(\.date))
        var cursor = calendar.startOfDay(for: endingOn)
        if !active.contains(DayKey.string(from: cursor, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while active.contains(DayKey.string(from: cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}
