import XCTest
@testable import WordRecitingApp

/// 一期-3：导航合同（首页是一级选项、且没有二级子区）。
final class NavigationModelTests: XCTestCase {

    func testHomeIsFirstZone() {
        XCTAssertEqual(AppZone.allCases.first, .home)
        XCTAssertEqual(AppZone.home.rawValue, "首页")
        XCTAssertEqual(AppZone.home.icon, "house")
    }

    /// 首页区只有「首页」一个二级项（`ContentView` 据此收折二级栏）。
    func testHomeZoneHasExactlyOneSection() {
        XCTAssertEqual(AppSection.home.zone, .home)
        XCTAssertEqual(AppSection.allCases.filter { $0.zone == .home }, [.home])
    }

    func testEverySectionBelongsToKnownZone() {
        for section in AppSection.allCases {
            XCTAssertTrue(AppZone.allCases.contains(section.zone), "\(section) 的 zone 不存在")
            XCTAssertFalse(section.icon.isEmpty)
        }
    }

    func testZoneOrderIsStable() {
        XCTAssertEqual(AppZone.allCases, [.home, .data, .learning, .settings])
    }
}
