import XCTest
@testable import WordRecitingApp

/// 真实内置词频表校验：资源必须存在、可用、带序单调。
final class WordFamilyResourceTests: XCTestCase {

    private struct Payload: Decodable {
        struct Family: Decodable { let rank: Int; let band: Int; let members: [String] }
        let source: String
        let families: [Family]
    }

    func testBundledProviderIsAvailable() throws {
        let provider = try XCTUnwrap(
            WordFrequency.bundled,
            "word_families.json 未生成或未登记进 Package.swift")
        XCTAssertFalse(provider.sourceName.isEmpty)
    }

    func testCommonWordsHaveBands() throws {
        let provider = try XCTUnwrap(WordFrequency.bundled)
        for word in ["the", "be", "have", "make", "government"] {
            XCTAssertNotNil(provider.band(for: word), "缺常用词：\(word)")
        }
    }

    func testHighFrequencyWordRanksBeforeLowFrequencyWord() throws {
        let provider = try XCTUnwrap(WordFrequency.bundled)
        let high = try XCTUnwrap(provider.rank(for: "the"))
        let low = try XCTUnwrap(provider.rank(for: "government"))
        XCTAssertLessThan(high, low)
    }

    func testRankIsStrictlyIncreasingAndBandIsNonDecreasing() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "word_families", withExtension: "json"),
            "资源未登记进 Package.swift")
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(payload.families.count, 2000, "词族数过少，疑似只生成了片段")

        var previousRank = 0
        var previousBand = 1
        for family in payload.families {
            XCTAssertGreaterThan(family.rank, previousRank, "rank 必须严格递增")
            XCTAssertGreaterThanOrEqual(family.band, previousBand, "band 不得随 rank 下降")
            XCTAssertTrue((1...25).contains(family.band), "band 越界：\(family.band)")
            XCTAssertFalse(family.members.isEmpty, "词族为空：rank \(family.rank)")
            previousRank = family.rank
            previousBand = family.band
        }
    }
}
