import AppKit
import XCTest
@testable import tiled

/// A neighbour that cannot reach the splitter leaves a gap between tiles.
///
/// Live report (2026-10-11): two Terminal windows snapped to the top-left
/// and bottom-left sixths. Dragging their shared divider left a gap between
/// them. The capture trace showed the neighbour (top-left) written to
/// `minY=424` but applied at `minY=430`: the app keeps the window's top edge
/// and rounds its height down to a whole character row, so its bottom edge
/// falls short of the splitter. The reassert reconciles the *dragged*
/// window's achieved edge (stage 2) but never reads the neighbour back, so
/// the splitter stays where the cursor left it and the gap stands.
///
/// This pins the fix (stage 5): after the settle, a neighbour that fell short
/// of the splitter pulls the splitter back to its achieved edge, and the
/// tiles abut. The app model below keeps the top edge and rounds the height
/// down to a whole row.
final class NeighbourRoundingTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    /// The app model: a written window keeps its top edge (`maxY`) and rounds
    /// its height down to a whole 16pt row. Idempotent, like a real
    /// row-gridding app.
    private static let cell: CGFloat = 16

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        gateway.writtenFrame = { _, target in
            let height = (target.height / Self.cell).rounded(.down) * Self.cell
            return CGRect(
                x: target.minX, y: target.maxY - height,
                width: target.width, height: height)
        }
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.screen] }, deathConfirmation: 0)
    }

    private func tile(_ handle: WindowHandle, into slot: Slot) {
        gateway.focused = handle
        controller.handle(slot: slot)
    }

    func testStackedSixthsStayFlushWhenTheAppRoundsTheNeighbour() {
        let top = gateway.addWindow(frame: CGRect(x: 0, y: 600, width: 700, height: 400))
        tile(top, into: .sixthTopLeft)
        let bottom = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        tile(bottom, into: .sixthBottomLeft)

        // Drag the BOTTOM window's top edge up to 0.62 of the canvas frame
        // (not a whole number of rows): an echo tick, then the escape — the
        // shape a live drag streams. This moves the shared left-column row
        // splitter.
        let bounds = Self.screen.visibleFrame
        var echo = gateway.frame(of: bottom)!
        echo.size.height -= 10
        gateway.simulateChange(bottom, to: echo)
        var dragged = gateway.frame(of: bottom)!
        dragged.size.height = 0.62 * bounds.height - dragged.minY
        gateway.simulateChange(bottom, to: dragged)

        controller.mouseLifted()

        let topFrame = gateway.frame(of: top)!
        let bottomFrame = gateway.frame(of: bottom)!
        XCTAssertEqual(
            bottomFrame.maxY, topFrame.minY, accuracy: 0.5,
            "the two stacked tiles abut at the splitter: no gap, no overlap. "
                + "top=\(topFrame) bottom=\(bottomFrame)")
    }
}
