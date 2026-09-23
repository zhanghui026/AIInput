import CoreGraphics
import XCTest
@testable import AIInput

final class PanelAnchorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 77, width: 1512, height: 872)
    private let size = CGSize(width: 680, height: 220)

    func testAnchorsBelowTheTextAlignedWithItsLeftEdge() {
        let text = CGRect(x: 300, y: 600, width: 120, height: 18)
        let result = PanelPlacement.anchored(below: text, panelSize: size, visibleFrame: screen)

        XCTAssertEqual(result.side, .below)
        XCTAssertEqual(result.frame.maxY, text.minY - 10)
        XCTAssertEqual(result.frame.minX, text.minX - PanelPlacement.contentInset)
        XCTAssertEqual(result.frame.size, size)
    }

    func testFlipsAboveTheTextNearTheBottomOfTheScreen() {
        let text = CGRect(x: 300, y: 150, width: 120, height: 18)
        let result = PanelPlacement.anchored(below: text, panelSize: size, visibleFrame: screen)

        XCTAssertEqual(result.side, .above)
        XCTAssertEqual(result.frame.minY, text.maxY + 10)
    }

    func testAnchoredPanelIsClampedInsideTheScreen() {
        let text = CGRect(x: 1450, y: 600, width: 40, height: 18)
        let result = PanelPlacement.anchored(below: text, panelSize: size, visibleFrame: screen)

        XCTAssertLessThanOrEqual(result.frame.maxX, screen.maxX - 8)
        XCTAssertGreaterThanOrEqual(result.frame.minX, screen.minX + 8)
    }

    func testTopCenterSitsInTheUpperPartOfTheScreen() {
        let result = PanelPlacement.topCenter(panelSize: size, visibleFrame: screen)

        XCTAssertEqual(result.side, .below)
        XCTAssertEqual(result.frame.midX, screen.midX)
        XCTAssertEqual(result.frame.maxY, screen.maxY - screen.height * 0.18, accuracy: 0.5)
    }

    func testPinnedRestoresTheTopLeftAndStaysOnScreen() {
        let pinned = PanelPlacement.pinned(
            topLeft: CGPoint(x: 200, y: 800),
            panelSize: size,
            visibleFrame: screen
        )
        XCTAssertEqual(pinned.side, .below)
        XCTAssertEqual(pinned.frame.minX, 200)
        XCTAssertEqual(pinned.frame.maxY, 800)

        let offscreen = PanelPlacement.pinned(
            topLeft: CGPoint(x: 5000, y: 5000),
            panelSize: size,
            visibleFrame: screen
        )
        XCTAssertTrue(screen.contains(offscreen.frame))
    }

    func testAXRectsConvertToCocoaCoordinates() {
        // 主屏高 982：AX 原点在左上，Cocoa 原点在左下。
        let cocoa = PanelPlacement.cocoaRect(
            fromAX: CGRect(x: 100, y: 200, width: 50, height: 20),
            primaryScreenHeight: 982
        )
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 762, width: 50, height: 20))
    }
}
