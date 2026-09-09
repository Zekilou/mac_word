import XCTest
@testable import WordRecitingApp

final class MasteryPresentationTests: XCTestCase {

    func testPercentTextClampsAndRounds() {
        XCTAssertEqual(MasteryPresentation.percentText(0.847), "85%")
        XCTAssertEqual(MasteryPresentation.percentText(0.0), "0%")
        XCTAssertEqual(MasteryPresentation.percentText(1.0), "100%")
        XCTAssertEqual(MasteryPresentation.percentText(1.4), "100%")
        XCTAssertEqual(MasteryPresentation.percentText(-0.2), "0%")
    }

    func testLevelIndexBoundaries() {
        XCTAssertEqual(MasteryPresentation.levelIndex(0.34), 0)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.35), 1)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.69), 1)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.70), 2)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.89), 2)
        XCTAssertEqual(MasteryPresentation.levelIndex(0.90), 3)
    }

    func testLevelLabels() {
        XCTAssertEqual(MasteryPresentation.levelLabel(0.1), "低")
        XCTAssertEqual(MasteryPresentation.levelLabel(0.5), "中")
        XCTAssertEqual(MasteryPresentation.levelLabel(0.8), "较高")
        XCTAssertEqual(MasteryPresentation.levelLabel(0.95), "高")
    }

    func testHelpTextStatesUncertainty() {
        XCTAssertTrue(MasteryPresentation.helpText(0.8).contains("不是精确测量"))
        XCTAssertTrue(MasteryPresentation.helpText(0.8).contains("80%"))
    }
}

final class FrequencyBandPresentationTests: XCTestCase {

    func testBandLabel() {
        XCTAssertEqual(FrequencyBandPresentation.bandLabel(1), "1k 带")
        XCTAssertEqual(FrequencyBandPresentation.bandLabel(25), "25k 带")
        XCTAssertEqual(FrequencyBandPresentation.bandLabel(0), "表外")
        XCTAssertEqual(FrequencyBandPresentation.bandLabel(nil), "—")
    }

    func testRankText() {
        XCTAssertEqual(FrequencyBandPresentation.rankText(1001), "全表第 1001 位")
        XCTAssertNil(FrequencyBandPresentation.rankText(0))
        XCTAssertNil(FrequencyBandPresentation.rankText(nil))
    }

    func testHelpTextIsHonest() {
        XCTAssertTrue(FrequencyBandPresentation.helpText(band: 2, rank: 1001).contains("参考坐标"))
        XCTAssertTrue(FrequencyBandPresentation.helpText(band: nil, rank: nil).contains("没有词频坐标"))
    }
}
