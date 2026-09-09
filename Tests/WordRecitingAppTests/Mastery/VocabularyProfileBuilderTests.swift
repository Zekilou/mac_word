import XCTest
@testable import WordRecitingApp

final class VocabularyProfileBuilderTests: XCTestCase {

    func testEstimatedKnownCombinesObservedAndPriorExtrapolation() {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 1, observedCount: 2, sumBelief: 1.8)],
            bandFamilyCounts: [1: 10])

        let band1 = profile.bands[0]
        XCTAssertEqual(band1.totalFamilies, 10)
        XCTAssertEqual(band1.observedFamilies, 2)
        XCTAssertEqual(band1.meanBelief, 0.9, accuracy: 0.0001)
        XCTAssertEqual(band1.estimatedKnownFamilies, 1.8 + 8 * 0.90, accuracy: 0.0001)
        XCTAssertEqual(profile.estimatedKnownTotal, band1.estimatedKnownFamilies, accuracy: 0.0001)
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
}
