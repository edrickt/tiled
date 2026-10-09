import AppKit
import XCTest
@testable import tiled

/// The minimum-size clamp, end to end: what macOS does to a window that
/// is pushed narrower than it can physically be, and what the write
/// policy owes the user when it happens.
///
/// Probed behavior (live AX, AppKit window with `contentMinSize` 400):
/// a frame write below the minimum clamps the *size* but lands the
/// *position* exactly - target (1300, 300, 150, 350) applied
/// (1300, 300, 400, 350) - so the window keeps its origin and grows
/// away from it. A target rect hugging the screen's right edge (or
/// bottom edge: size writes anchor at the window's top-left) therefore
/// sails the clamped window off the screen instead of letting it simply
/// stop shrinking.
///
/// The reported bug is the drag shape below: a middle third expanded
/// over a right third until the right third cannot shrink any more. The
/// neighbor is re-pushed on mouse-up to a rect narrower than its floor;
/// the window must stay in the boundaries of the screen and stop at its
/// minimum size, never slide off the edge.
final class MinimumSizeTests: XCTestCase {
    /// Deterministic display: every rect is checked against this one,
    /// never the host Mac's screen.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    /// The floor the target app enforces: it refuses to be narrower (or
    /// shorter) than this, which is what the clamp write models below.
    private static let minSize = CGSize(width: 500, height: 200)

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        // The probed clamp: the size write lands at the window's floor
        // and the position write lands exactly, so the window keeps its
        // origin and grows away from it.
        gateway.writtenFrame = { [minSize = Self.minSize] _, target in
            CGRect(
                origin: target.origin,
                size: CGSize(
                    width: max(target.width, minSize.width),
                    height: max(target.height, minSize.height)))
        }
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.screen] }, deathConfirmation: 0)
    }

    /// Tiles `handle`'s window into `slot` as a user hotkey would.
    private func tile(_ handle: WindowHandle, into slot: Slot) {
        gateway.focused = handle
        controller.handle(slot: slot)
    }

    /// The reported bug, minimised: middle third + right third, expand
    /// the middle third rightward past the point where the right third
    /// can still shrink. The right third is re-pushed on mouse-up to
    /// 300pt wide - below its 500pt floor - and macOS hangs the clamped
    /// window off the right screen edge. It must instead hold the screen
    /// edge and stop shrinking at its floor.
    func testRightThirdThatCannotShrinkStaysInsideTheScreen() {
        let a = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        tile(a, into: .sixthMiddle)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 100, width: 550, height: 400))
        tile(b, into: .sixthRight)
        // Both default tiles are 533pt wide: the right third fits above
        // its floor, so its later trouble is the drag's doing alone.
        XCTAssertEqual(
            gateway.frame(of: b),
            controller.canvas(for: Self.screen.id).grid.rect(
                for: .sixthRight, in: Self.screen.visibleFrame),
            "the right third starts inside its tile")

        // Expand the middle third rightward to x=1300: a close echo tick
        // settles first, then the drag escapes to the splitters (the
        // shape a real edge drag streams).
        var echo = gateway.frame(of: a)!
        echo.size.width -= 10
        gateway.simulateChange(a, to: echo)
        let dragged = CGRect(x: echo.minX, y: echo.minY, width: 1300 - echo.minX, height: echo.height)
        gateway.simulateChange(a, to: dragged)

        // Mouse-up commits the neighbor re-push: the right third is
        // asked for [1300, 1600] (300pt, below its floor) and the clamp
        // applies the probed distortion.
        controller.mouseLifted()
        let lifted = XCTestExpectation(description: "coalesced push on mouse-up")
        DispatchQueue.main.async {
            let frame = self.gateway.frame(of: b)!
            XCTAssertTrue(
                Self.screen.visibleFrame.contains(frame),
                "the right third stays in the boundaries of the screen, "
                    + "instead of sliding off the edge: \(frame)")
            XCTAssertEqual(
                frame, CGRect(x: 1100, y: 0, width: 500, height: 1000),
                "it simply stops shrinking: the floor-width window holds "
                    + "the screen edge it was pinned to")
            lifted.fulfill()
        }
        wait(for: [lifted], timeout: 1)
    }
}
