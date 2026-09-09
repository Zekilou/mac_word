import Foundation
import GRDB

/// 每日快照回放器：单遍重放 `comp_word_event`，在每个自然日收盘时落一条 `DailyStat`。
/// @ai: 与 `MasterySystem` 共用同一套 BKT 参数/先验，保证「快照历史」与「实时后验」同口径；
///      全量重算（先清后写），幂等。启动时由 `VocabularyMaintenance.backfillDailyStats` 触发。
enum DailyStatRecorder {
    static let moduleId = "daily_stat"
    /// 与概率主口径对齐（唯一来源 `WordMarkState`）。
    static let knownThreshold = WordMarkState.knownThreshold
    static let unknownThreshold = WordMarkState.unknownThreshold
    private static let nodePrefix = "analytics-day-"

    /// 快照节点 id（date 为 `yyyy-MM-dd`）。
    static func nodeId(date: String) -> String { nodePrefix + date }

    // MARK: - 对外

    /// 全量重算每日快照并落库（自开写事务）。
    @discardableResult
    static func rebuild(world: World, now: Date = Date(),
                        parameters: BKTParameters = .default,
                        calendar: Calendar = .current) throws -> [DailyStat] {
        try world.database.dbWriter.write { db in
            try rebuild(world: world, db: db, now: now,
                        parameters: parameters, calendar: calendar)
        }
    }

    /// 读回全部快照（按日期升序）。
    static func loadAll(world: World) throws -> [DailyStat] {
        try world.database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT payload_json FROM comp_analytics_cache
                WHERE module_id = ?
                ORDER BY scope_hash ASC
                """, arguments: [moduleId])
            return rows.compactMap { row in
                guard let json: String = row["payload_json"] else { return nil }
                return try? JSONDecoder().decode(DailyStat.self, from: Data(json.utf8))
            }
        }
    }

    // MARK: - 回放（db 版本，在传入事务内）

    /// 全量重算（db 版本）：先清空 `analytics_day` 节点，再按事件流重建。
    @discardableResult
    static func rebuild(world: World, db: Database, now: Date,
                        parameters: BKTParameters = .default,
                        calendar: Calendar = .current) throws -> [DailyStat] {
        let events = try world.graph.allWordEvents(db)
        let frequencies = try world.graph.allLemmaFrequencies(db)
        let regionCounts = try world.graph.distinctRegionCounts(db)
        let ratings = try world.graph.allReviewRecords(db)
        let today = dayKey(now, calendar: calendar)

        try world.registry.deleteNodes(db, kind: .analyticsDay)
        guard !events.isEmpty || !ratings.isEmpty else { return [] }

        var bandByLemma: [EntityID: Int] = [:]
        bandByLemma.reserveCapacity(frequencies.count)
        for (lemmaId, row) in frequencies { bandByLemma[lemmaId] = row.band }

        var belief: [EntityID: Double] = [:]
        var firstSeen = Set<EntityID>()
        var byDay: [String: DailyStat] = [:]
        var currentDay: String?
        var dayEvents = 0
        var dayNewWords = 0

        for event in events {
            let day = dayKey(event.occurredAt, calendar: calendar)
            if let open = currentDay, day != open {
                byDay[open] = snapshot(day: open, belief: belief, bandByLemma: bandByLemma,
                                       events: dayEvents, newWords: dayNewWords)
                dayEvents = 0
                dayNewWords = 0
            }
            currentDay = day

            let lemmaId = event.lemmaId
            let base = belief[lemmaId]
                ?? BKTModel.prior(band: bandByLemma[lemmaId], parameters: parameters)
            if firstSeen.insert(lemmaId).inserted { dayNewWords += 1 }
            if let kind = WordEventKind(rawValue: event.kind) {
                belief[lemmaId] = BKTModel.update(
                    belief: base, kind: kind, trust: event.trust,
                    distinctRegions: regionCounts[lemmaId] ?? 1,
                    parameters: parameters)
            } else {
                belief[lemmaId] = base
            }
            dayEvents += 1
        }
        if let currentDay {
            byDay[currentDay] = snapshot(day: currentDay, belief: belief, bandByLemma: bandByLemma,
                                         events: dayEvents, newWords: dayNewWords)
        }

        var reviewByDay: [String: (reviews: Int, passed: Int)] = [:]
        for row in ratings {
            let day = dayKey(row.ratedAt, calendar: calendar)
            var entry = reviewByDay[day] ?? (reviews: 0, passed: 0)
            entry.reviews += 1
            if row.rating >= Rating.good.rawValue { entry.passed += 1 }
            reviewByDay[day] = entry
        }

        for day in reviewByDay.keys where byDay[day] == nil {
            byDay[day] = carriedForward(day: day, byDay: byDay)
        }
        if byDay[today] == nil {
            byDay[today] = carriedForward(day: today, byDay: byDay)
        }

        let stats = byDay.keys.sorted().map { day -> DailyStat in
            let base = byDay[day]!
            let review = reviewByDay[day]
            return DailyStat(
                date: day,
                known: base.known, learning: base.learning, unknown: base.unknown,
                events: base.events, newWords: base.newWords,
                reviews: review?.reviews ?? 0,
                retention: review.map { Double($0.passed) / Double($0.reviews) },
                knownByBand: base.knownByBand)
        }

        for stat in stats {
            let id = nodeId(date: stat.date)
            try world.registry.insertNode(db, id: id, kind: .analyticsDay, createdAt: now)
            let json = String(data: try JSONEncoder().encode(stat), encoding: .utf8) ?? "{}"
            try world.registry.upsertComponent(db, AnalyticsCacheComponent(
                entityId: id, moduleId: moduleId, scopeHash: stat.date,
                computedAt: now, payloadJson: json))
        }
        return stats
    }

    // MARK: - 私有

    private static func snapshot(day: String, belief: [EntityID: Double],
                                 bandByLemma: [EntityID: Int],
                                 events: Int, newWords: Int) -> DailyStat {
        var known = 0
        var learning = 0
        var unknown = 0
        var knownByBand: [String: Int] = [:]
        for (lemmaId, value) in belief {
            if value >= knownThreshold {
                known += 1
                knownByBand[String(bandByLemma[lemmaId] ?? 0), default: 0] += 1
            } else if value <= unknownThreshold {
                unknown += 1
            } else {
                learning += 1
            }
        }
        return DailyStat(date: day, known: known, learning: learning, unknown: unknown,
                         events: events, newWords: newWords, reviews: 0, retention: nil,
                         knownByBand: knownByBand)
    }

    /// 无词事件的日：沿用最近一个已记录日的收盘状态（后验只被词事件改变）。
    private static func carriedForward(day: String, byDay: [String: DailyStat]) -> DailyStat {
        let base = byDay.keys.filter { $0 < day }.sorted().last.flatMap { byDay[$0] }
        return DailyStat(date: day,
                         known: base?.known ?? 0, learning: base?.learning ?? 0,
                         unknown: base?.unknown ?? 0,
                         events: 0, newWords: 0, reviews: 0, retention: nil,
                         knownByBand: base?.knownByBand ?? [:])
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        DayKey.string(from: date, calendar: calendar)
    }
}
