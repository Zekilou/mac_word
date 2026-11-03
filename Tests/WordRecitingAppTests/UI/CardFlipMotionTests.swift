import XCTest
@testable import WordRecitingCore
@testable import WordRecitingUI

/// 翻卡动画的纯函数测试。
/// @ai: 这些参数决定「翻面像不像实体的卡」，改常量前先用测试钉住不变量：
///      正反面显隐必须互补、90° 时两面都处于半透明（交叉淡出发生在侧棱处）、
///      明暗/缩放必须落在合理区间（否则卡片会闪黑或缩成一张邮票）。
final class CardFlipMotionTests: XCTestCase {

    // MARK: - 朝向判定

    func testIsFrontAcrossTurn() {
        XCTAssertTrue(CardFlipMotion.isFront(0))
        XCTAssertTrue(CardFlipMotion.isFront(80))
        XCTAssertFalse(CardFlipMotion.isFront(90))
        XCTAssertFalse(CardFlipMotion.isFront(120))
        XCTAssertFalse(CardFlipMotion.isFront(180))
    }

    func testNormalizeWrapsIntoHalfCircle() {
        XCTAssertEqual(CardFlipMotion.normalize(0), 0, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.normalize(180), 180, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.normalize(190), 170, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.normalize(-90), 90, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.normalize(360), 0, accuracy: 0.0001)
    }

    // MARK: - 正反面显隐

    func testFrontAndBackVisibilityAreComplementary() {
        for degrees in stride(from: 0.0, through: 180.0, by: 5.0) {
            let front = CardFlipMotion.frontVisible(degrees)
            let back = CardFlipMotion.backVisible(degrees)
            XCTAssertEqual(front + back, 1, accuracy: 0.0001, "角度 \(degrees) 两面透明度不互补")
        }
    }

    func testFacesAreFullyOpaqueAtTheirOwnSide() {
        XCTAssertEqual(CardFlipMotion.frontVisible(0), 1, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.backVisible(180), 1, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.frontVisible(180), 0, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.backVisible(0), 0, accuracy: 0.0001)
    }

    /// 90°（卡片呈侧棱）附近两面都在半透明区间——切换发生在「看不见」的时刻。
    func testCrossFadeHappensAtTheEdge() {
        let front = CardFlipMotion.frontVisible(90)
        XCTAssertGreaterThan(front, 0)
        XCTAssertLessThan(front, 1)
        // 远离侧棱时不能有半透明残留（否则正面会有「幽灵重影」）。
        XCTAssertEqual(CardFlipMotion.frontVisible(70), 1, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.frontVisible(110), 0, accuracy: 0.0001)
    }

    // MARK: - 透视与光照

    /// 透视必须是**无量纲**的：同样的 strength 下，翻转中途的放大率只由 strength 决定，
    /// 与卡片尺寸无关。
    /// @ai: 旧实现用绝对点数（420pt），卡片一换尺寸手感就崩，而且无法判断数值大小含义。
    ///      这里把「放大率上界」钉住：strength=4 时近端不超过 1.2×。
    func testPerspectiveIsDimensionlessAndBounded() {
        let halfWidth: CGFloat = 260        // 卡片半宽
        func maxMagnification(_ strength: CGFloat) -> CGFloat {
            let d = strength * (halfWidth * 2)
            return d / (d - halfWidth)
        }
        XCTAssertLessThan(maxMagnification(CardFlipMotion.defaultPerspectiveStrength), 1.2)
        XCTAssertGreaterThan(maxMagnification(CardFlipMotion.defaultPerspectiveStrength), 1.0)
        // 强度越大越接近平行投影（放大率单调收敛到 1）。
        XCTAssertGreaterThan(maxMagnification(2), maxMagnification(4))
        XCTAssertGreaterThan(maxMagnification(4), maxMagnification(8))
    }

    /// strength 必须为正，否则 m34 会变成正数（反向透视，卡片会被翻到屏幕外）。
    func testPerspectiveStrengthIsPositive() {
        XCTAssertGreaterThan(CardFlipMotion.defaultPerspectiveStrength, 0)
    }

    func testShadingStaysInSafeRange() {
        for degrees in stride(from: 0.0, through: 180.0, by: 5.0) {
            let shading = CardFlipMotion.shading(degrees)
            XCTAssertGreaterThanOrEqual(shading, 0.8)
            XCTAssertLessThanOrEqual(shading, 1.0)
        }
        // 平放时最亮、侧棱时最暗（方向写反了会像卡片自发光）。
        XCTAssertEqual(CardFlipMotion.shading(0), 1, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.shading(180), 1, accuracy: 0.0001)
        XCTAssertLessThan(CardFlipMotion.shading(90), CardFlipMotion.shading(0))
        XCTAssertEqual(CardFlipMotion.shading(90), 0.82, accuracy: 0.0001)
    }

    func testIsSettledOnlyAtTheTwoFaces() {
        XCTAssertTrue(CardFlipMotion.isSettled(0))
        XCTAssertTrue(CardFlipMotion.isSettled(180))
        XCTAssertFalse(CardFlipMotion.isSettled(45))
        XCTAssertFalse(CardFlipMotion.isSettled(90))
    }

    func testScaleIsSubtleAndSymmetric() {
        XCTAssertEqual(CardFlipMotion.scale(0), 1, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.scale(180), 1, accuracy: 0.0001)
        let mid = CardFlipMotion.scale(90)
        XCTAssertLessThan(mid, 1)
        XCTAssertGreaterThan(mid, 0.9, "翻转中途的缩小必须克制，否则像卡片被吞掉")
    }

    func testLiftReturnsToRestAtBothFaces() {
        XCTAssertEqual(CardFlipMotion.liftOffset(0), 0, accuracy: 0.0001)
        XCTAssertEqual(CardFlipMotion.liftOffset(180), 0, accuracy: 0.0001)
        XCTAssertLessThan(CardFlipMotion.liftOffset(90), 0, "侧棱时应向上抬起")
    }
}
