import XCTest
@testable import WordRecitingApp

final class EventTimelinePresenterTests: XCTestCase {

    func testKindLabels() {
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.seen), "出现过")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.lookup), "查词")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.markKnown), "标记会")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.markUnknown), "标记不会")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.quizCorrect), "答对")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.quizWrong), "答错")
    }

    func testRegionLabels() {
        XCTAssertEqual(EventTimelinePresenter.regionLabel("study"), "复习")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("rss"), "RSS 阅读")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("generate"), "生成文章")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("dictionary"), "词典")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("init"), "词汇初始化")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("legacy"), "旧数据迁移")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("unknown"), "其他")
    }

    func testItemsMapTrustToActive() {
        let now = Date()
        let rows = [
            GraphQueries.WordEventRow(eventId: "E1", lemmaId: "L1", regionId: "R1",
                                      kind: "mark_known", trust: 1.0, occurredAt: now),
            GraphQueries.WordEventRow(eventId: "E2", lemmaId: "L1", regionId: "R2",
                                      kind: "seen", trust: 0.0, occurredAt: now)
        ]
        let items = EventTimelinePresenter.items(
            from: rows, regionKinds: ["R1": "dictionary", "R2": "rss"], now: now)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kindLabel, "标记会")
        XCTAssertEqual(items[0].regionLabel, "词典")
        XCTAssertTrue(items[0].isActive)
        XCTAssertEqual(items[1].trustLabel, "被动")
        XCTAssertFalse(items[1].isActive)
    }

    func testUnknownEventKindFallsBackToRawValue() {
        let rows = [GraphQueries.WordEventRow(
            eventId: "E1", lemmaId: "L1", regionId: "R1",
            kind: "legacy", trust: 1.0, occurredAt: Date())]
        XCTAssertEqual(EventTimelinePresenter.items(from: rows).first?.kindLabel, "legacy")
    }

    func testRelativeText() {
        let now = Date()
        XCTAssertEqual(EventTimelinePresenter.relativeText(
            from: now.addingTimeInterval(-10), now: now), "刚刚")
        XCTAssertEqual(EventTimelinePresenter.relativeText(
            from: now.addingTimeInterval(-120), now: now), "2 分钟前")
        XCTAssertEqual(EventTimelinePresenter.relativeText(
            from: now.addingTimeInterval(-7200), now: now), "2 小时前")
        XCTAssertEqual(EventTimelinePresenter.relativeText(
            from: now.addingTimeInterval(-172800), now: now), "2 天前")
    }
}
