import Foundation

/// 打分上下文：策略据此区分用途。
struct ScoringContext: Sendable, Equatable {
    enum Purpose: String, Sendable {
        /// 造文选目标词。
        case articleTargets
        /// 阅读高亮。
        case readingHighlight
        /// 初始化段落。
        case initParagraph
    }

    let purpose: Purpose
    let now: Date
    /// 期望词频带窗口（nil = 不限）。
    let bandWindow: ClosedRange<Int>?
}

/// 选词打分策略：分数越高越优先。
/// @ai: 确定性纯函数，不碰数据库；取词方式（top-N / 阈值）由调用方决定。
protocol WordScoringStrategy: Sendable {
    var id: WordScoringID { get }
    func score(_ f: WordFeatures, context: ScoringContext) -> Double
}

/// 复习排期策略：算下一次调度状态。
/// @ai: 纯函数，不改 DB——由调用方（StudySystem）写回。
protocol ReviewIntervalPolicy: Sendable {
    var id: SchedulerID { get }
    func next(state: ScheduleStateComponent, rating: Rating,
              features: WordFeatures, now: Date) -> ScheduleStateComponent
}
