import XCTest
@testable import WordRecitingApp

final class WordFrequencyBandCountsTests: XCTestCase {

    private let fixture = """
    {"source":"test","families":[
      {"rank":1,"band":1,"members":["the","a"]},
      {"rank":2,"band":1,"members":["be"]},
      {"rank":1001,"band":2,"members":["abandon","abandoned"]},
      {"rank":1002,"band":2,"members":["ability"]}
    ]}
    """

    private func makeProvider() throws -> BundledWordFrequencyProvider {
        try BundledWordFrequencyProvider(data: Data(fixture.utf8))
    }

    func testBandFamilyCountsCountFamiliesNotMembers() throws {
        let provider = try makeProvider()
        XCTAssertEqual(provider.bandFamilyCounts[1], 2)
        XCTAssertEqual(provider.bandFamilyCounts[2], 2)
    }

    func testTotalFamilyCount() throws {
        XCTAssertEqual(try makeProvider().totalFamilyCount, 4)
    }

    func testMissingBandIsAbsent() throws {
        XCTAssertNil(try makeProvider().bandFamilyCounts[9])
    }
}
