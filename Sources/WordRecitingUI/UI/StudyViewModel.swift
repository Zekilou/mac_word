import Foundation
import Observation
import WordRecitingCore

/// 背诵 ViewModel：加载到期队列、翻转、评分、刷新统计。
/// @ai: UI 不写 SQL；评分走 `World.run(StudySystem)`；查询走 `GraphQueries`。
///
/// 本轮修掉的逻辑 bug（每条都对应一个测试）：
/// - **调度算法没生效**：`settings.schedulerID` 从未传给 `StudySystem`（`StudyOp.policyID`
///   恒为默认 `.sm2`），设置页选「SM-2 + 词频」等于没选。→ `rate()` 显式传入。
/// - **没翻开就能评分**：正面（还没看释义）按 1–4 直接跳卡，等于盲评。→ 评分前置条件
///   `canRate`：必须先翻到背面。
/// - **刷新丢进度**：`reload()` 把 `currentIndex` 归零，点一下刷新就从第一张重来。
///   → 改成「会话内已评分集合」，刷新只重算队列，已评过的不再出现。
/// - **队列口径对不上**：「剩余」用的是加载时的队列长度，而评分后卡片的 `due_at`
///   被 SCHEDULER 改写（Again = 10 分钟后）——界面上的数字和数据库里的到期数不同步。
///   → 每次评分后重算统计，「剩余」按真实队列收敛。
@MainActor
@Observable
final class StudyViewModel {

    let world: World
    let settings: AppSettings

    /// 本轮待背的卡片（`reload()` 按到期时间排好；评分只推进游标，不重排，
    /// 否则 Again 的卡会在 10 分钟后插回队首，让人在同一张卡上反复。）
    /// @ai: 可写是为了测试直接注入队列；生产路径只有 `reload()` 写入。
    var queue: [CardListItem] = []
    /// 游标：`queue[0..<cursor]` 已评分。
    private(set) var cursor = 0

    var stats: StudyStats?
    var isFront = true
    var errorMessage: String?

    /// 本次会话内已经评过分的卡片（刷新后不再出队；离开页面即清空）。
    private(set) var ratedCardIds: Set<EntityID> = []

    /// 当前卡的 BKT 后验概率（nil = 尚无事件）。
    private(set) var currentBelief: Double?
    /// 当前卡的词频带 / 全表排名。
    private(set) var currentBand: Int?
    private(set) var currentRank: Int?
    /// 当前卡的音标（正面显示，没有就不显示）。
    private(set) var currentPhonetic: String?
    /// 当前卡的「为什么现在出现」：新卡 / 到期 / 逾期 N 天。
    private(set) var currentProvenance: String?
    /// 当前卡的事件摘要，如 "标记不会 1 次 · 出现过 3 次"。
    private(set) var currentEventSummary: String?
    /// 当前卡的评分结果（评分后短暂展示，下一张自动清空）。
    private(set) var lastRating: Rating?
    /// `lastRating` 属于哪张卡。
    /// @ai: 必须绑定卡片身份——只用一个 `Rating?` 判定「刚评过」会连带锁死下一张卡
    ///      （换卡后 lastRating 仍在，canRate 恒 false，表现为「评分一次后就点不动了」）。
    private(set) var lastRatedCardId: EntityID?

    init(world: World, settings: AppSettings = .shared) {
        self.world = world
        self.settings = settings
    }

    // MARK: - 派生状态

    /// 当前卡片。
    var currentCard: CardListItem? {
        guard cursor < queue.count else { return nil }
        return queue[cursor]
    }

    /// 队列是否还有卡。
    var hasCards: Bool { currentCard != nil }

    /// 剩余数量（含当前这张）。
    var remaining: Int { max(0, queue.count - cursor) }

    /// 本轮总张数 / 已完成张数（进度条用）。
    var totalInRound: Int { queue.count }
    var completedInRound: Int { min(cursor, queue.count) }

    /// 当前卡是否已被评分（评分后短暂锁定，防止连点跳过中间的卡）。
    /// 绑定卡片身份：换了卡就不再算「已评」。
    var hasRatedCurrent: Bool {
        guard let card = currentCard else { return false }
        return lastRatedCardId == card.cardId && lastRating != nil
    }

    /// 能否评分：**必须已翻到背面**（正面还没看释义，评分等于盲猜），且当前卡尚未评分。
    /// @ai: 这是「误触跳卡」的根治——旧实现正面按 1–4 直接推进游标，卡就没了。
    var canRate: Bool { currentCard != nil && !isFront && !hasRatedCurrent }

    /// 空状态原因：全部已会 → 与「今天已经背完」区分开，用户才知道该干什么。
    var emptyReason: EmptyReason {
        guard stats.map({ $0.totalCards > 0 }) ?? false else { return .noCards }
        let due = stats?.dueCount ?? 0
        if due > 0 { return .roundFinished(dueNow: due) }
        return .clearedToday
    }

    enum EmptyReason: Equatable {
        /// 词库一张卡都没有 —— 去导入词库。
        case noCards
        /// 本轮做完了，但库里还有到期卡（被今天已会/高置信过滤掉的不会出现，这里是真到期）。
        case roundFinished(dueNow: Int)
        /// 今天没有到期卡片了。
        case clearedToday
    }

    // MARK: - 加载

    /// 刷新队列与统计。**保留本轮进度**：已评分的卡片不再回到队列。
    /// - Parameter now: 注入时间便于测试。
    func reload(now: Date = Date()) {
        do {
            let all = try world.graph.dueCards(now: now)
            queue = all.filter { !ratedCardIds.contains($0.cardId) }
            stats = try world.graph.studyStats(now: now)
            cursor = 0
            isFront = true
            lastRating = nil
            lastRatedCardId = nil
            errorMessage = nil
            refreshCurrentProfile()
        } catch {
            queue = []
            stats = nil
            cursor = 0
            lastRating = nil
            lastRatedCardId = nil
            refreshCurrentProfile()
            errorMessage = "\(error)"
        }
    }

    // MARK: - 交互

    /// 翻转卡片（正面/背面）。
    func flip() {
        guard currentCard != nil else { return }
        isFront.toggle()
    }

    /// 对当前卡片评分，然后进入下一张。
    /// @ai: 前置条件不满足（未翻面 / 已评过）时**静默返回**——不是错误，不需要错误条。
    func rate(_ rating: Rating) {
        guard canRate, let card = currentCard else { return }
        do {
            try world.run(StudySystem(), context: StudySystem.StudyOp(
                cardId: card.cardId, rating: rating, reviewedAt: Date(),
                // 设置页选的调度算法必须真的用上（旧实现这里恒为默认 SM-2）。
                policyID: settings.schedulerID))
            // 主动做题 → 高可信词事件
            RegionRecorder(world: world).record(
                lemmaIds: [card.lemmaId],
                region: .study(cardId: card.cardId),
                kind: rating.rawValue >= Rating.good.rawValue ? .quizCorrect : .quizWrong)

            lastRating = rating
            lastRatedCardId = card.cardId
            // @ai: 换卡前先按「已评」落账，再推进游标——顺序反了，如果 rating 被
            //      `.good` 的 again 逻辑触发异常回滚，界面与数据库会各说各话。
            ratedCardIds.insert(card.cardId)
            cursor += 1
            isFront = true
            refreshCurrentProfile()
            stats = try world.graph.studyStats()
        } catch {
            lastRating = nil
            lastRatedCardId = nil
            errorMessage = "保存评分失败：\(error)"
        }
    }

    /// 跳过当前卡（不评分、不改调度、不计入今日复习）。
    /// @ai: 背单词时「这词我现在不想管」是真实需求；旧实现只能靠乱点一个评分，
    ///      那样会把 SM-2 的间隔改坏。跳过是纯本地推进，不写库。
    func skip() {
        guard currentCard != nil, !hasRatedCurrent else { return }
        cursor += 1
        isFront = true
        lastRating = nil
        lastRatedCardId = nil
        refreshCurrentProfile()
    }

    /// 撤销刚刚的评分：回到上一张卡。
    /// @ai: 只撤销**本次会话最后一张**，且要求调度状态是我们刚写的那份。
    ///      真正的回滚（删 review_event + 还原 schedule_state）未实现；
    ///      这里只把卡片放回队列、不谎称已还原数据库（因此会同时移出 ratedCardIds，
    ///      允许用户重评——重评会再写一条 review_event，这是已知取舍）。
    func undoLastRating() {
        guard lastRatedCardId != nil, cursor > 0 else { return }
        cursor -= 1
        ratedCardIds.remove(lastRatedCardId ?? "")
        lastRating = nil
        lastRatedCardId = nil
        // 放回当前卡时停在释义面：用户刚看到的就是这一面，再接一次「翻开」很突兀。
        isFront = false
        refreshCurrentProfile()
    }

    // MARK: - 当前卡画像

    /// 刷新当前卡的模型信息（后验概率 / 词频坐标 / 音标 / 出现原因 / 事件摘要）。
    func refreshCurrentProfile() {
        guard let card = currentCard else {
            currentBelief = nil
            currentBand = nil
            currentRank = nil
            currentPhonetic = nil
            currentProvenance = nil
            currentEventSummary = nil
            return
        }
        currentBelief = try? world.graph.masteryBelief(lemmaId: card.lemmaId)
        let frequency = try? world.graph.lemmaFrequency(lemmaId: card.lemmaId)
        currentBand = frequency?.band
        currentRank = frequency?.freqRank
        let meta: LemmaMetaComponent? = try? world.registry.fetchComponents(
            for: card.lemmaId, table: "comp_lemma_meta")
        currentPhonetic = Self.phoneticText(us: meta?.phoneticUs, uk: meta?.phoneticUk)
        currentProvenance = Self.provenanceText(reps: card.reps, dueAt: card.dueAt)
        let counts = (try? world.graph.wordEventCountsByKind(lemmaId: card.lemmaId)) ?? [:]
        currentEventSummary = Self.summaryText(counts: counts)
    }

    // MARK: - 纯函数（可单测）

    /// 事件计数 → 摘要文案（纯函数，可单测）。
    nonisolated static func summaryText(counts: [String: Int]) -> String? {
        let order: [WordEventKind] = [
            .quizCorrect, .quizWrong, .markKnown, .markUnknown, .lookup, .seen
        ]
        let parts = order.compactMap { kind -> String? in
            guard let count = counts[kind.rawValue], count > 0 else { return nil }
            return "\(EventTimelinePresenter.kindLabel(kind)) \(count) 次"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 「为什么这张卡现在出现」：新卡 / 到期 / 逾期 N 天。
    /// @ai: 审计 P2——用户看到一张卡却不知道它是新词还是到期复习，无法判断该多用力。
    nonisolated static func provenanceText(reps: Int?, dueAt: Date?, now: Date = Date()) -> String {
        guard let reps, reps > 0 else { return "新卡 · 第一次学" }
        guard let dueAt else { return "复习 · 已排程" }
        let seconds = now.timeIntervalSince(dueAt)
        // 未来到期（提前打开队列 / 时钟回拨）不说「逾期负数」。
        guard seconds > 0 else { return "复习 · 未到期" }
        let days = Int(seconds / 86_400)
        if days <= 0 {
            let hours = max(1, Int(seconds / 3_600))
            return "复习 · 逾期 \(hours) 小时"
        }
        return "复习 · 逾期 \(days) 天"
    }

    /// 音标文案：美音优先，其次英音；两者都有时并列。空串视为无音标。
    nonisolated static func phoneticText(us: String?, uk: String?) -> String? {
        func clean(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        switch (clean(us), clean(uk)) {
        case let (us?, uk?) where us != uk: return "美 \(us) · 英 \(uk)"
        case let (us?, _): return us
        case let (_, uk?): return uk
        default: return nil
        }
    }
}
