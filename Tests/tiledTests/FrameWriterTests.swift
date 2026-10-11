import CoreGraphics
import XCTest
@testable import tiled

/// FrameWriter through its interface: the one write policy every push
/// path shares - no-op skip, off-Space deferral, echo marking, and the
/// convergence check each accepted write must declare. Fake gateway,
/// recording collaborators; no controller, no AX.
final class FrameWriterTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var echoed: [WindowID] = []
    private var checked: [WindowID] = []
    private var checkedSpaces: [TilingSpaceKey] = []
    private var staleMarks: [TilingSpaceKey] = []
    private var events: [String] = []

    private let canvas = TilingSpaceKey(
        screen: ScreenID(rawValue: 1), space: SpaceID(rawValue: 10))

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        echoed = []
        checked = []
        checkedSpaces = []
        staleMarks = []
        events = []
    }

    private func makeWriter(
        visible: @escaping (TilingSpaceKey) -> Bool = { _ in true },
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    ) -> FrameWriter {
        FrameWriter(
            gateway: gateway,
            isVisible: visible,
            boundsOf: { _ in bounds },
            markStale: { [weak self] space in
                self?.events.append("stale")
                self?.staleMarks.append(space)
            },
            markExpected: { [weak self] id, _ in
                self?.events.append("echo")
                self?.echoed.append(id)
            },
            scheduleCheck: { [weak self] id, space in
                self?.events.append("check")
                self?.checked.append(id)
                self?.checkedSpaces.append(space)
            },
            log: { _ in })
    }

    func testAcceptedWriteMarksExpectedThenSchedulesTheDeclaredCheck() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let target = CGRect(x: 40, y: 40, width: 300, height: 200)
        // Order matters: the expectation must exist before the write can
        // echo, and the check is scheduled only after the write landed.
        gateway.writtenFrame = { [weak self] _, target in
            self?.events.append("write")
            return target
        }

        let result = makeWriter().write(7, handle: handle, to: target, on: canvas, check: .rollback)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 1)
        XCTAssertEqual(gateway.writes.first?.0, handle)
        XCTAssertEqual(gateway.writes.first?.1, target)
        XCTAssertEqual(echoed, [7])
        XCTAssertEqual(checked, [7])
        XCTAssertEqual(checkedSpaces, [canvas])
        XCTAssertEqual(events, ["echo", "write", "check"])
    }

    func testNoOpTargetIsSkippedWithoutWritingOrArmingAnEcho() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let handle = gateway.addWindow(frame: frame)

        let result = makeWriter().write(7, handle: handle, to: frame, on: canvas, check: .rollback)

        XCTAssertEqual(result, .skippedNoOp)
        XCTAssertTrue(gateway.writes.isEmpty)
        XCTAssertTrue(echoed.isEmpty)
        XCTAssertTrue(checked.isEmpty)
    }

    func testHiddenCanvasDefersBeforeAnyWritePolicyRuns() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let handle = gateway.addWindow(frame: frame)

        // A no-op target proves visibility is judged first: the write
        // defers and the canvas is marked stale instead of skipped.
        let result = makeWriter(visible: { _ in false })
            .write(7, handle: handle, to: frame, on: canvas, check: .rollback)

        XCTAssertEqual(result, .deferredOffSpace)
        XCTAssertTrue(gateway.writes.isEmpty)
        XCTAssertTrue(echoed.isEmpty)
        XCTAssertTrue(checked.isEmpty)
        XCTAssertEqual(staleMarks, [canvas])
    }

    func testExplicitNoneCheckWritesWithoutScheduling() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let target = CGRect(x: 40, y: 40, width: 300, height: 200)

        let result = makeWriter().write(7, handle: handle, to: target, on: canvas, check: .none)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 1)
        XCTAssertEqual(echoed, [7])
        XCTAssertTrue(checked.isEmpty)
    }

    func testRefusedWriteArmsTheEchoButSchedulesNoCheck() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        gateway.refuseNextWrites(handle)
        let target = CGRect(x: 40, y: 40, width: 300, height: 200)

        let result = makeWriter().write(7, handle: handle, to: target, on: canvas, check: .rollback)

        XCTAssertEqual(result, .refused)
        XCTAssertEqual(echoed, [7])
        XCTAssertTrue(checked.isEmpty)
    }

    // MARK: Minimum-size clamp

    /// The probed app behavior, modeled on the fake: the position write
    /// lands exactly and only the size snaps to the window's floor, so
    /// the window keeps its origin and grows away from it. A target
    /// hugging the right screen edge then sails the clamped window off
    /// it; the write policy owes the user a window inside the bounds.
    private func clampWidthToFloor(_ floor: CGFloat) -> (WindowHandle, CGRect) -> CGRect {
        { _, target in
            CGRect(
                origin: target.origin,
                size: CGSize(width: max(target.width, floor), height: target.height))
        }
    }

    func testClampedWriteIsRepinnedAtTheScreenEdgeItHolds() {
        let handle = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 533, height: 1000))
        gateway.writtenFrame = clampWidthToFloor(500)
        let target = CGRect(x: 1300, y: 0, width: 300, height: 1000)

        let result = makeWriter().write(7, handle: handle, to: target, on: canvas, check: .rollback)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 2, "the repin is its own write")
        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 1100, y: 0, width: 500, height: 1000),
            "the floor-width window holds the screen edge and simply stops shrinking")
        XCTAssertEqual(
            echoed, [7, 7],
            "the echo re-arms at the frame the window really has, not the one it was refused")
    }

    func testClampedWriteAnchoredOnTheScreenEdgeIsLeftAlone() {
        // Shrinking from the right: the floor keeps the window's origin,
        // which IS the screen edge, so it stopped shrinking in bounds
        // already and a second write would only fight the app.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 533, height: 1000))
        gateway.writtenFrame = clampWidthToFloor(500)
        let target = CGRect(x: 0, y: 0, width: 300, height: 1000)

        let result = makeWriter().write(7, handle: handle, to: target, on: canvas, check: .rollback)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 1)
        XCTAssertEqual(gateway.frame(of: handle), CGRect(x: 0, y: 0, width: 500, height: 1000))
    }

    func testClampedHeightIsRepinnedAtTheBottomScreenEdge() {
        // Size writes anchor at the window's top-left (AppKit: its top
        // edge), so a clamped height grows downward past the bottom
        // screen edge for a target hugging it.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 533))
        gateway.writtenFrame = { _, target in
            let height = max(target.height, 500)
            return CGRect(
                x: target.minX, y: target.maxY - height,
                width: target.width, height: height)
        }
        let target = CGRect(x: 0, y: 0, width: 800, height: 300)

        let result = makeWriter().write(7, handle: handle, to: target, on: canvas, check: .rollback)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 0, y: 0, width: 800, height: 500),
            "the floor-height window holds the bottom screen edge")
    }

    func testStraddlingTargetTheAppAppliedIsNeverYankedBack() {
        // Only a clamp - a size the app refused - triggers the repair.
        // A frame that legitimately runs past the bounds (a pre-tile
        // restore straddling displays) is the app's own placement and
        // must be left exactly where it lands.
        let handle = gateway.addWindow(frame: CGRect(x: 100, y: 0, width: 300, height: 300))
        let target = CGRect(x: 1500, y: 0, width: 300, height: 300)

        let result = makeWriter().write(7, handle: handle, to: target, on: canvas, check: .rollback)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 1)
        XCTAssertEqual(gateway.frame(of: handle), target)
    }
}
