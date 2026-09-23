import CoreGraphics
import XCTest
@testable import AIInput

final class PanelPlacementTests: XCTestCase {
    func testPlacesPanelBelowCursorWhenThereIsRoom() {
        let result = PanelPlacement.nearCursor(
            cursor: CGPoint(x: 600, y: 700),
            panelSize: CGSize(width: 480, height: 168),
            visibleFrame: CGRect(x: 0, y: 77, width: 1512, height: 872)
        )

        XCTAssertEqual(result.side, .below)
        XCTAssertEqual(result.frame, CGRect(x: 360, y: 516, width: 480, height: 168))
    }

    func testPlacesPanelAboveCursorNearBottomEdge() {
        let result = PanelPlacement.nearCursor(
            cursor: CGPoint(x: 600, y: 100),
            panelSize: CGSize(width: 480, height: 168),
            visibleFrame: CGRect(x: 0, y: 77, width: 1512, height: 872)
        )

        XCTAssertEqual(result.side, .above)
        XCTAssertEqual(result.frame, CGRect(x: 360, y: 116, width: 480, height: 168))
    }

    func testPlacementUsesNegativeScreenCoordinates() {
        let result = PanelPlacement.nearCursor(
            cursor: CGPoint(x: -1850, y: 300),
            panelSize: CGSize(width: 480, height: 168),
            visibleFrame: CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        )

        XCTAssertEqual(result.side, .below)
        XCTAssertEqual(result.frame, CGRect(x: -1912, y: 116, width: 480, height: 168))
    }

    func testPlacementAtEachScreenCornerRemainsInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let cases: [(cursor: CGPoint, side: PanelPlacement.Side, frame: CGRect)] = [
            (
                CGPoint(x: 0, y: 0),
                .above,
                CGRect(x: 8, y: 16, width: 300, height: 200)
            ),
            (
                CGPoint(x: 1000, y: 0),
                .above,
                CGRect(x: 692, y: 16, width: 300, height: 200)
            ),
            (
                CGPoint(x: 0, y: 800),
                .below,
                CGRect(x: 8, y: 584, width: 300, height: 200)
            ),
            (
                CGPoint(x: 1000, y: 800),
                .below,
                CGRect(x: 692, y: 584, width: 300, height: 200)
            ),
        ]

        for testCase in cases {
            let result = PanelPlacement.nearCursor(
                cursor: testCase.cursor,
                panelSize: CGSize(width: 300, height: 200),
                visibleFrame: visibleFrame
            )

            XCTAssertEqual(result.side, testCase.side)
            XCTAssertEqual(result.frame, testCase.frame)
        }
    }

    func testGrowingBelowNearBottomEdgeRemainsFullyVisible() {
        let visibleFrame = CGRect(x: 0, y: 77, width: 1512, height: 872)
        let result = PanelPlacement.resizedFrame(
            from: CGRect(x: 360, y: 77, width: 480, height: 168),
            to: CGSize(width: 480, height: 284),
            placementSide: .below,
            visibleFrames: [visibleFrame]
        )

        XCTAssertEqual(result, CGRect(x: 360, y: 85, width: 480, height: 284))
    }

    func testResizeStaysOnScreenContainingCurrentFrame() {
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = CGRect(x: -1200, y: -100, width: 1200, height: 900)
        let result = PanelPlacement.resizedFrame(
            from: CGRect(x: -900, y: 100, width: 480, height: 168),
            to: CGSize(width: 480, height: 284),
            placementSide: .below,
            visibleFrames: [primary, secondary]
        )

        XCTAssertEqual(result, CGRect(x: -900, y: -16, width: 480, height: 284))
    }

    func testPanelLargerThanUsableFrameIsShrunkToFit() {
        let result = PanelPlacement.nearCursor(
            cursor: CGPoint(x: 260, y: 50),
            panelSize: CGSize(width: 500, height: 400),
            visibleFrame: CGRect(x: 100, y: -50, width: 320, height: 200),
            margin: 10
        )

        XCTAssertEqual(result.frame, CGRect(x: 110, y: -40, width: 300, height: 180))
    }
}
