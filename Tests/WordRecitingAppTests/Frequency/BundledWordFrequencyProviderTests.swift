import XCTest
@testable import WordRecitingApp

final class BundledWordFrequencyProviderTests: XCTestCase {

    private let fixture = """
    {"source":"test-3k","families":[
      {"rank":1,"band":1,"members":["the","a","an"]},
      {"rank":2,"band":1,"members":["be","is","was"]},
      {"rank":1001,"band":2,"members":["abandon","abandoned","abandonment"]}
    ]}
    """

    private func makeProvider() throws -> BundledWordFrequencyProvider {
        try BundledWordFrequencyProvider(data: Data(fixture.utf8))
    }

    func testSourceName() throws {
        XCTAssertEqual(try makeProvider().sourceName, "test-3k")
    }

    func testBandLookupIsCaseInsensitiveAndFamilyAware() throws {
        let p = try makeProvider()
        XCTAssertEqual(p.band(for: "The"), 1)
        XCTAssertEqual(p.band(for: "abandoned"), 2)
        XCTAssertEqual(p.band(for: "abandonment"), 2)
    }

    func testRankLookup() throws {
        let p = try makeProvider()
        XCTAssertEqual(p.rank(for: "the"), 1)
        XCTAssertEqual(p.rank(for: "abandon"), 1001)
    }

    func testUnknownWordReturnsNil() throws {
        let p = try makeProvider()
        XCTAssertNil(p.band(for: "zzzzz"))
        XCTAssertNil(p.rank(for: "zzzzz"))
    }

    func testDuplicateMemberKeepsBestRank() throws {
        let json = """
        {"source":"dup","families":[
          {"rank":50,"band":1,"members":["run"]},
          {"rank":5,"band":1,"members":["run"]}
        ]}
        """
        let p = try BundledWordFrequencyProvider(data: Data(json.utf8))
        XCTAssertEqual(p.rank(for: "run"), 5)
    }

    func testInvalidFormatThrows() {
        XCTAssertThrowsError(try BundledWordFrequencyProvider(data: Data("{}".utf8)))
    }

    /// 资源缺失时优雅降级：不崩溃，返回 nil。
    func testBundledResourceLoadsIfPresent() throws {
        guard let provider = BundledWordFrequencyProvider(bundledIn: .module) else {
            throw XCTSkip("word_families.json 未生成，跳过")
        }
        XCTAssertFalse(provider.sourceName.isEmpty)
    }

    func testFacadeDoesNotCrashWhenResourceMissing() {
        _ = WordFrequency.bundled
    }
}
