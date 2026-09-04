import XCTest
@testable import tiled

/// Screen-ownership rule for multi-display tiling: the display showing the
/// largest share of a window owns it, so a straddled window never jitters
/// between screens on its midpoint. Pure function over synthetic frames —
/// no displays, AX, or UI needed.
final class ScreenOwnershipTests: XCTestCase {
    // Two 1920-wide displays side by side in AppKit coords.
    private static let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    private static let frames = [left, right]

    private func owner(of frame: CGRect) -> Int? {
        TilingController.owningScreenIndex(frames: Self.frames, for: frame)
    }

    // MARK: Containment

    func testFullyInsideLeftPicksLeft() {
        XCTAssertEqual(owner(of: CGRect(x: 100, y: 100, width: 800, height: 600)), 0)
    }

    func testFullyInsideRightPicksRight() {
        XCTAssertEqual(owner(of: CGRect(x: 2000, y: 100, width: 800, height: 600)), 1)
    }

    func testExactScreenBoundsPicksThatScreen() {
        XCTAssertEqual(owner(of: Self.right), 1)
    }

    // MARK: Straddles

    func testStraddlePicksMostlyVisibleSide() {
        // 400px on the left, 800px on the right — midpoint is irrelevant.
        XCTAssertEqual(owner(of: CGRect(x: 1520, y: 100, width: 1200, height: 600)), 1)
        XCTAssertEqual(owner(of: CGRect(x: 1120, y: 100, width: 1200, height: 600)), 0)
    }

    func testMidpointAloneDoesNotDecide() {
        // A thin middle screen holds the midpoint but not the majority:
        // left keeps 60px, the sliver 80px, right takes 120px.
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 80, height: 1080),
            CGRect(x: 2000, y: 0, width: 1920, height: 1080),
        ]
        let frame = CGRect(x: 1860, y: 100, width: 260, height: 600)
        XCTAssertTrue(frames[1].contains(CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertEqual(
            TilingController.owningScreenIndex(frames: frames, for: frame), 2)
    }

    func testEvenSplitResolvesToFirstScreen() {
        XCTAssertEqual(owner(of: CGRect(x: 960, y: 100, width: 1920, height: 600)), 0)
    }

    // MARK: Degenerate

    func testOffScreenYieldsNilForFallback() {
        XCTAssertNil(owner(of: CGRect(x: -3000, y: -3000, width: 400, height: 300)))
    }

    // MARK: Vertically stacked displays

    func testStackedStraddlePicksMajoritySide() {
        // Equal widths, so a width-only comparison ties at the first
        // screen: 700px of window on top, 300px on the bottom.
        let frames = [
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]
        let topHeavy = CGRect(x: 200, y: 780, width: 800, height: 1000)
        XCTAssertEqual(
            TilingController.owningScreenIndex(frames: frames, for: topHeavy), 0)
        let bottomHeavy = CGRect(x: 200, y: 300, width: 800, height: 1000)
        XCTAssertEqual(
            TilingController.owningScreenIndex(frames: frames, for: bottomHeavy), 1)
    }

    func testStackedEvenSplitResolvesToFirstScreen() {
        let frames = [
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]
        XCTAssertEqual(
            TilingController.owningScreenIndex(
                frames: frames, for: CGRect(x: 200, y: 580, width: 800, height: 1000)),
            0)
    }

    func testStackedMidpointAloneDoesNotDecide() {
        // A thin band between the displays holds the midpoint but not the
        // majority: top keeps 120px, the band 80px, bottom takes 60px.
        // (With two contiguous screens the midpoint always lies in the
        // majority portion, so divergence needs the three-way split —
        // mirroring the side-by-side sliver test.)
        let frames = [
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
            CGRect(x: 0, y: 1000, width: 1920, height: 80),
            CGRect(x: 0, y: 0, width: 1920, height: 1000),
        ]
        let frame = CGRect(x: 200, y: 940, width: 800, height: 260)
        XCTAssertTrue(frames[1].contains(CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertEqual(
            TilingController.owningScreenIndex(frames: frames, for: frame), 0)
    }

    // MARK: Degenerate

    func testZeroSizeFrameYieldsNilForFallback() {
        // A zero-size rect overlaps no screen with positive area, so the
        // caller falls back to midpoint-then-main.
        XCTAssertNil(owner(of: CGRect(x: 500, y: 500, width: 0, height: 0)))
    }

    func testEmptyFramesYieldNil() {
        XCTAssertNil(TilingController.owningScreenIndex(frames: [], for: Self.left))
    }
}
