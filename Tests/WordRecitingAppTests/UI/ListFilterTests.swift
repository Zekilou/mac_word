import XCTest
@testable import WordRecitingCore
@testable import WordRecitingUI

/// 统一筛选逻辑测试。
/// @ai: 筛选语义必须被钉住——「同维度多选取并集、跨维度取交集」是全应用共用的规则，
///      改了会影响 4 个列表的行为。
final class ListFilterTests: XCTestCase {

    /// 测试用词（满足 FilterableWord）。
    private struct Word: FilterableWord {
        let id: String
        var text = ""
        var definition: String? = nil
        var mark: WordMarkState = .pending
        var belief: Double? = nil
        var band: Int? = nil
        var seen = 0
        var events = 0
        var due: Date? = nil
        var reps = 0
        var updated: Date? = nil

        var filterID: String { id }
        var wordText: String { text }
        var wordDefinition: String? { definition }
        var wordMark: WordMarkState { mark }
        var wordBelief: Double? { belief }
        var wordBand: Int? { band }
        var wordSeenCount: Int { seen }
        var wordEventCount: Int { events }
        var wordDueAt: Date? { due }
        var wordReps: Int { reps }
        var wordUpdatedAt: Date? { updated }
    }

    private let all: Set<WordFacet> = [.text, .definition, .mark, .band, .belief, .due, .seen, .sort]

    private func sample() -> [Word] {
        [
            Word(id: "a", text: "abandon", definition: "放弃", mark: .unknown,
                 belief: 0.1, band: 1, seen: 3, events: 5),
            Word(id: "b", text: "battle", definition: "战斗", mark: .known,
                 belief: 0.95, band: 2, seen: 1, events: 2),
            Word(id: "c", text: "combustion", definition: "燃烧", mark: .learning(0.5),
                 belief: 0.5, band: 5, seen: 0, events: 1),
            Word(id: "d", text: "zebra", definition: nil, mark: .pending,
                 belief: nil, band: nil, seen: 0, events: 0)
        ]
    }

    // MARK: - 文本搜索

    func testTextSearchMatchesWordText() {
        var f = ListFilter()
        f.query = "aban"
        let out = f.apply(sample(), facets: [.text])
        XCTAssertEqual(out.map(\.id), ["a"])
    }

    func testTextSearchIsCaseInsensitive() {
        var f = ListFilter()
        f.query = "BATTLE"
        XCTAssertEqual(f.apply(sample(), facets: [.text]).map(\.id), ["b"])
    }

    func testDefinitionSearchOnlyWhenFacetEnabled() {
        var f = ListFilter()
        f.query = "燃烧"
        // 未启用 .definition → 只搜词面，搜不到。
        XCTAssertTrue(f.apply(sample(), facets: [.text]).isEmpty)
        // 启用 .definition → 命中。
        XCTAssertEqual(f.apply(sample(), facets: [.text, .definition]).map(\.id), ["c"])
    }

    func testEmptyQueryDoesNotFilter() {
        let f = ListFilter()
        XCTAssertEqual(f.apply(sample(), facets: all).count, 4)
    }

    // MARK: - 掌握度（同维度并集）

    func testMarkFilterIsUnionWithinDimension() {
        var f = ListFilter()
        f.marks = [.unknown, .known]
        let out = f.apply(sample(), facets: [.mark])
        XCTAssertEqual(Set(out.map(\.id)), ["a", "b"])
    }

    func testEmptyMarkSetMeansNoRestriction() {
        let f = ListFilter()
        XCTAssertEqual(f.apply(sample(), facets: [.mark]).count, 4)
    }

    func testLearningMarkMapsToBucket() {
        var f = ListFilter()
        f.marks = [.learning]
        XCTAssertEqual(f.apply(sample(), facets: [.mark]).map(\.id), ["c"])
    }

    // MARK: - 跨维度交集

    func testCrossDimensionIsIntersection() {
        var f = ListFilter()
        f.marks = [.known, .learning]   // b, c
        f.bands = [.top1k, .top3k]      // 1k 带 = a, 1-3k = b  → 只有 b 同时满足
        let out = f.apply(sample(), facets: [.mark, .band])
        XCTAssertEqual(out.map(\.id), ["b"])
    }

    // MARK: - 词频分档

    func testFrequencyBucketBoundaries() {
        XCTAssertEqual(FrequencyBucket.from(band: 1), .top1k)
        XCTAssertEqual(FrequencyBucket.from(band: 2), .top3k)
        XCTAssertEqual(FrequencyBucket.from(band: 3), .top3k)
        XCTAssertEqual(FrequencyBucket.from(band: 4), .top5k)
        XCTAssertEqual(FrequencyBucket.from(band: 5), .top5k)
        XCTAssertEqual(FrequencyBucket.from(band: 6), .top10k)
        XCTAssertEqual(FrequencyBucket.from(band: 10), .top10k)
        XCTAssertEqual(FrequencyBucket.from(band: 11), .top25k)
        XCTAssertEqual(FrequencyBucket.from(band: nil), .outside)
        XCTAssertEqual(FrequencyBucket.from(band: 0), .outside)
    }

    func testBandFilterExcludesWordsWithoutFrequency() {
        var f = ListFilter()
        f.bands = [.top1k]
        XCTAssertEqual(f.apply(sample(), facets: [.band]).map(\.id), ["a"])
    }

    // MARK: - 概率分档

    func testBeliefBucketBoundaries() {
        XCTAssertEqual(BeliefBucket.from(belief: nil), .none)
        XCTAssertEqual(BeliefBucket.from(belief: 0.1), .unknown)
        XCTAssertEqual(BeliefBucket.from(belief: 0.19), .unknown)
        XCTAssertEqual(BeliefBucket.from(belief: 0.2), .low)
        XCTAssertEqual(BeliefBucket.from(belief: 0.34), .low)
        XCTAssertEqual(BeliefBucket.from(belief: 0.35), .mid)
        XCTAssertEqual(BeliefBucket.from(belief: 0.84), .mid)
        XCTAssertEqual(BeliefBucket.from(belief: 0.85), .high)
        XCTAssertEqual(BeliefBucket.from(belief: 1.0), .high)
    }

    // MARK: - 到期分档

    func testDueBucketFromDates() {
        let now = Date()
        XCTAssertEqual(DueBucket.from(dueAt: nil, now: now), .unscheduled)
        XCTAssertEqual(DueBucket.from(dueAt: now.addingTimeInterval(-3600), now: now), .overdue)
        XCTAssertEqual(DueBucket.from(dueAt: now.addingTimeInterval(86400 * 3), now: now), .future)
    }

    // MARK: - 计数（facet counting）

    /// chip 上的计数必须**忽略自身维度**的选择，否则用户一选就归零。
    func testMarkCountsIgnoreMarkSelection() {
        var f = ListFilter()
        f.marks = [.known]
        let counts = f.markCounts(sample(), facets: [.mark])
        XCTAssertEqual(counts[.known], 1)
        XCTAssertEqual(counts[.unknown], 1)
        XCTAssertEqual(counts[.learning], 1)
        XCTAssertEqual(counts[.pending], 1)
    }

    /// 但必须**遵守其他维度**的筛选。
    func testMarkCountsRespectOtherFacets() {
        var f = ListFilter()
        f.bands = [.top1k]   // 只有 a（unknown）
        let counts = f.markCounts(sample(), facets: [.mark, .band])
        XCTAssertEqual(counts[.unknown], 1)
        XCTAssertNil(counts[.known])
    }

    // MARK: - 排序

    func testSortAlphabeticalIsDeterministic() {
        var f = ListFilter()
        f.sort = .alphabetical
        XCTAssertEqual(f.apply(sample(), facets: [.sort]).map(\.text),
                       ["abandon", "battle", "combustion", "zebra"])
    }

    func testSortMasteryAscPutsNilFirst() {
        var f = ListFilter()
        f.sort = .masteryAsc
        let out = f.apply(sample(), facets: [.sort])
        XCTAssertEqual(out.first?.id, "d", "无概率的词应排最前（最需要学）")
    }

    func testSortBandAscPutsOutsideLast() {
        var f = ListFilter()
        f.sort = .bandAsc
        let out = f.apply(sample(), facets: [.sort])
        XCTAssertEqual(out.map(\.id), ["a", "b", "c", "d"], "表外词应排最后")
    }

    func testSortSeenDesc() {
        var f = ListFilter()
        f.sort = .seenDesc
        let out = f.apply(sample(), facets: [.sort])
        XCTAssertEqual(out.first?.id, "a")
    }

    // MARK: - 状态

    func testIsActiveReflectsAnyFilter() {
        XCTAssertFalse(ListFilter().isActive)
        var f = ListFilter()
        f.query = "x"
        XCTAssertTrue(f.isActive)
        f.clear()
        XCTAssertFalse(f.isActive)
        f.marks = [.known]
        XCTAssertTrue(f.isActive)
    }

    func testClearKeepsSort() {
        var f = ListFilter()
        f.sort = .alphabetical
        f.query = "x"
        f.marks = [.known]
        f.clear()
        XCTAssertEqual(f.sort, .alphabetical, "清除筛选不应重置排序偏好")
        XCTAssertFalse(f.isActive)
    }

    // MARK: - 空维度不生效

    func testFacetsNotEnabledAreIgnored() {
        var f = ListFilter()
        f.marks = [.known]
        // 未启用 .mark → 即便设置了 marks 也不筛。
        XCTAssertEqual(f.apply(sample(), facets: [.text]).count, 4)
    }
}
