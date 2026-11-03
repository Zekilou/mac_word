import Foundation

/// 一个「词」在任意列表里要暴露的**全部**标量。
///
/// @ai: 这是全应用唯一的词快照。历史上同一个词被 4 个残缺 DTO 各表达一次
///      （`CardListItem` / `RecordedLemma` / `LemmaCandidate` / `WordFeatures`），
///      字段各不相同、谁也不全，导致「统一筛选」落地时每个列表都得临时适配一次，
///      而且换一个口径（比如加词频带）要改 8 处 JOIN。
///
///      现在：**连接只写一份**（`GraphQueries+WordCore.swift`），字段只在这里定义一次。
///      新增字段 = 改 `wordCoreColumnsByLemma` / `wordCoreColumnsByCard` + 这里的 `let`，
///      所有查询与所有 DTO 自动跟上。
///
///      身份说明：`WordCore` 的身份是 **lemmaId**（一个词）。
///      「每张卡一行」的列表用 `WordCore.Card`（= 词快照 + cardId），
///      因为同一个词在 3 个词库里可以有 3 张卡，两者的行集不是一回事。
public struct WordCore: Sendable, Equatable, Identifiable {
    /// 一个词的身份是 lemmaId（不是 cardId——卡片是「学习目标」，可以有多张）。
    public var id: EntityID { lemmaId }

    public let lemmaId: EntityID
    /// 词面（text_a，已清洗；可能带音标尾巴，见 `plainText`）。
    public let text: String
    /// 主释义（text_b，已清洗并保留换行）。
    public let definition: String?
    /// 用户显式掌握度（comp_user_known.mastery：0=无记录 / 1=不会 / 2=会 / 1~2 渐变）。
    public let mastery: Double?
    /// BKT 后验掌握度概率；nil = 尚无事件。
    public let belief: Double?
    /// 词频带 1..25；nil = 无坐标（词表外或词表未加载）。
    public let band: Int?
    /// 全表排名（band 内顺序，越小越高频）。
    public let rank: Int?
    /// 出现过次数（seen_count，RSS 等自动累计）。
    public let seenCount: Int
    /// 词事件总数。
    public let eventCount: Int
    /// 上下文多样性：出现过的不同 region 数。
    public let contextCount: Int
    /// 最近一次词事件时间。
    public let lastEventAt: Date?
    /// 掌握度记录最近更新时间（排序用）。
    public let updatedAt: Date?
    /// 卡片调度状态；nil = 这个词没有卡。
    public let schedule: CardSchedule?

    /// 全参构造：全部字段有默认值，让「只知道一部分特征」的调用点（测试 / 调度兜底）
    /// 可以只写它关心的那几个，不必构造 13 个常量。
    /// @ai: 默认值必须保持「什么都不知道」的中性语义——不要给 mastery/belief 填 0，
    ///      0 与 nil 在这个模型里是两种含义（无记录 vs 概率为 0）。
    public init(
        lemmaId: EntityID,
        text: String = "",
        definition: String? = nil,
        mastery: Double? = nil,
        belief: Double? = nil,
        band: Int? = nil,
        rank: Int? = nil,
        seenCount: Int = 0,
        eventCount: Int = 0,
        contextCount: Int = 0,
        lastEventAt: Date? = nil,
        updatedAt: Date? = nil,
        schedule: CardSchedule? = nil
    ) {
        self.lemmaId = lemmaId
        self.text = text
        self.definition = definition
        self.mastery = mastery
        self.belief = belief
        self.band = band
        self.rank = rank
        self.seenCount = seenCount
        self.eventCount = eventCount
        self.contextCount = contextCount
        self.lastEventAt = lastEventAt
        self.updatedAt = updatedAt
        self.schedule = schedule
    }

    /// 卡片调度状态。
    /// @ai: `cardId` 是必需的——「这个词现在归哪张卡通」是排程身份，
    ///      少了它 UI 侧无法回写评分（历史上它是 `WordFeatures.CardSchedule` 的必填字段）。
    public struct CardSchedule: Sendable, Equatable {
        public let cardId: EntityID
        /// nil = 未排程（新卡，视为立即到期）。
        public let dueAt: Date?
        public let intervalDays: Double?
        public let reps: Int
        public let lapses: Int
        public let lastReviewedAt: Date?
    }
}

// MARK: - 派生视图

public extension WordCore {

    /// 「每张卡一行」的词 + 卡片身份。
    /// @ai: 卡片浏览 / 背诵队列 / 造文选词器都用它——这些列表的行集是**卡**，不是词。
    ///      它复用 `WordCore` 的全部字段，只额外钉住 `cardId`，所以筛选口径与词列表完全一致
    ///      （词频带、到期、概率在卡片侧同样可筛）。
    public struct Card: Sendable, Equatable, Identifiable {
        /// 卡片身份：与 `WordCore.id`（lemmaId）刻意区分——一张卡跨词库不复用。
        public var id: EntityID { cardId }

        public let cardId: EntityID
        public let word: WordCore

        public init(cardId: EntityID, word: WordCore) {
            self.cardId = cardId
            self.word = word
        }
    }

    /// 纯单词形式：剥离 "[音标]" / "(词性)" 尾巴，用于 UI 展示与匹配。
    /// @ai: 词面是匹配键（词频表按纯词形查），列表显示也不该带音标。
    public var plainText: String {
        var end = text.startIndex
        while end < text.endIndex, text[end].isLetter || text[end] == "-" || text[end] == "'" {
            text.formIndex(after: &end)
        }
        let stripped = String(text[..<end]).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? text : stripped
    }

    /// 统一掌握度状态判定（概率优先，无概率回退显式标记）。
    /// @ai: 全应用唯一口径——列表徽章、筛选、词块底色都走这里，禁止各页各写一遍。
    public var markState: WordMarkState {
        WordMarkState.from(belief: belief, mastery: mastery, seenCount: seenCount)
    }

    /// 空快照：只在「查不到这个语言模型特征」时作占位，避免调用方为 nil 分支写一套常量。
    /// @ai: 调度策略消费它时等价于「这个词什么都不知道」——与旧 `WordFeatures` 的空构造一致。
    public static func empty(lemmaId: EntityID) -> WordCore {
        WordCore(
            lemmaId: lemmaId, text: "", definition: nil,
            mastery: nil, belief: nil, band: nil, rank: nil,
            seenCount: 0, eventCount: 0, contextCount: 0,
            lastEventAt: nil, updatedAt: nil, schedule: nil)
    }
}

// MARK: - 卡片行 → 词快照

public extension WordCore.Card {
    public var lemmaId: EntityID { word.lemmaId }
    public var text: String { word.text }
    /// 纯单词形式（剥音标/词性尾巴）。
    public var plainText: String { word.plainText }
    public var definition: String? { word.definition }
    public var mastery: Double? { word.mastery }
    public var belief: Double? { word.belief }
    public var band: Int? { word.band }
    public var rank: Int? { word.rank }
    public var seenCount: Int { word.seenCount }
    public var eventCount: Int { word.eventCount }
    public var contextCount: Int { word.contextCount }
    public var lastEventAt: Date? { word.lastEventAt }
    public var updatedAt: Date? { word.updatedAt }
    public var schedule: WordCore.CardSchedule? { word.schedule }
    public var markState: WordMarkState { word.markState }

    // MARK: 卡片排程的便捷读法
    //
    // @ai: 卡片侧的历史调用点（背诵卡 / 卡片浏览 / 选词器）读的是「这张卡的排程」。
    //      `reps` 保持 **Optional** 语义——nil = 这张卡还没有 comp_schedule_state 行
    //      （与新卡「有行但 reps=0」区分开），这与收敛前的行为完全一致。

    public var dueAt: Date? { schedule?.dueAt }
    public var intervalDays: Double? { schedule?.intervalDays }
    public var reps: Int? { schedule?.reps }
    public var lapses: Int? { schedule?.lapses }
    public var lastReviewedAt: Date? { schedule?.lastReviewedAt }

    /// 把卡片身份换成另一张（只替换 cardId，保留词快照）。
    public func withCardId(_ cardId: EntityID) -> WordCore.Card {
        WordCore.Card(cardId: cardId, word: word)
    }
}
