import XCTest
@testable import tiled

/// The pure sizing every untile exit shares: the canvas's smallest slot
/// footprint, at the window's own origin, kept inside the visible frame.
final class UntiledSizeTests: XCTestCase {
    func testSizedUntileFrameKeepsOriginAndMatchesTileSize() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keeping: CGPoint(x: 12, y: 34), for: .quarters, in: bounds),
            CGRect(x: 12, y: 34, width: 800, height: 500))
        // A sixth's width is 1600 x (1/3) in the grid, one ulp away from
        // 1600 / 3, so it is read at the suite's sixth-width tolerance.
        let sixths = GridLayout().sizedUntileFrame(
            keeping: CGPoint(x: 12, y: 34), for: .sixths, in: bounds)
        XCTAssertEqual(sixths.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(sixths.height, 500)
        XCTAssertEqual(sixths.width, 1600.0 / 3.0, accuracy: 0.0001)
    }

    func testSizedUntileFrameRepinsInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keeping: CGPoint(x: 1500, y: 900), for: .quarters, in: bounds),
            CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testSizedUntileFrameDegenerateBoundsSkips() {
        let frame = GridLayout().sizedUntileFrame(
            keeping: CGPoint(x: 12, y: 34), for: .quarters, in: .zero)
        XCTAssertEqual(frame.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(frame.size, .zero)
        XCTAssertTrue(
            [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite))
    }
}
