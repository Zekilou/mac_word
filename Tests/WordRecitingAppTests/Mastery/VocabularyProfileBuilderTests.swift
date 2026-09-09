import XCTest
@testable import WordRecitingApp

final class VocabularyProfileBuilderTests: XCTestCase {

    /// 小样本（< minObservedForExtrapolation）不外推，只统计已观测词。
    func testSmallSampleBandIsNotExtrapolated() {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 1, observedCount: 2, sumBelief: 1.8)],
            bandFamilyCounts: [1: 10])

        let band1 = profile.bands[0]
        XCTAssertEqual(band1.totalFamilies, 10)
        XCTAssertEqual(band1.observedFamilies, 2)
        XCTAssertEqual(band1.meanBelief, 0.9, accuracy: 0.0001)
        XCTAssertEqual(band1.estimatedKnownFamilies, 1.8, accuracy: 0.0001)
        XCTAssertEqual(profile.estimatedKnownTotal, 1.8, accuracy: 0.0001)
        XCTAssertEqual(profile.totalFamilies, 10)
    }

    func testBandsAreSortedAscending() {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 3, observedCount: 1, sumBelief: 0.5)],
            bandFamilyCounts: [1: 5, 3: 5])
        XCTAssertEqual(profile.bands.map(\.band), [1, 3])
    }

    func testBandWithoutFrequencyTableStillAppears() {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 2, observedCount: 1, sumBelief: 0.4)],
            bandFamilyCounts: [:])
        XCTAssertEqual(profile.bands.count, 1)
        XCTAssertEqual(profile.bands[0].totalFamilies, 0)
        XCTAssertEqual(profile.bands[0].estimatedKnownFamilies, 0.4, accuracy: 0.0001)
        XCTAssertNil(profile.bands[0].coverage)
    }

    func testEmptyInput() {
        let profile = VocabularyProfileBuilder.build(bandStats: [], bandFamilyCounts: [:])
        XCTAssertTrue(profile.bands.isEmpty)
        XCTAssertEqual(profile.estimatedKnownTotal, 0, accuracy: 0.0001)
    }

    /// 观测充分时按平滑后的实测率外推（不是 BKT 先验）。
    func testExtrapolatesUsingSmoothedObservedRate() {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 1, observedCount: 100, sumBelief: 50)],
            bandFamilyCounts: [1: 200])

        // 平滑率 = 50 / (100 + 10) = 0.4545…；50 + 100 × 0.4545… = 95.4545…
        XCTAssertEqual(profile.bands[0].estimatedKnownFamilies,
                       50 + 100 * (50.0 / 110.0), accuracy: 0.0001)
    }

    /// 没有观测的带不贡献任何词汇量（哪怕词表里有 1000 个词族）。
    func testUnobservedBandContributesNothing() throws {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 1, observedCount: 1, sumBelief: 0.9)],
            bandFamilyCounts: [1: 10, 2: 1000])

        let band2 = try XCTUnwrap(profile.bands.first { $0.band == 2 })
        XCTAssertEqual(band2.estimatedKnownFamilies, 0, accuracy: 0.0001)
        XCTAssertEqual(profile.estimatedKnownTotal, 0.9, accuracy: 0.0001)
    }
}
