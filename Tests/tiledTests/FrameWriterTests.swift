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
    private var cancelled: [WindowID] = []
    private var baselines: [(WindowID, CGRect)] = []
    private var checked: [WindowID] = []
    private var checkedSpaces: [TilingSpaceKey] = []
    private var staleMarks: [TilingSpaceKey] = []
    private var events: [String] = []

    private let canvas = TilingSpaceKey(
        screen: ScreenID(rawValue: 1), space: SpaceID(rawValue: 10))

    /// The canvas's one visible frame: the boundary a clamped write is
    /// repinned against.
    private static let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        echoed = []
        cancelled = []
        baselines = []
        checked = []
        checkedSpaces = []
        staleMarks = []
        events = []
    }

    private func makeWriter(
        visible: @escaping (TilingSpaceKey) -> Bool = { _ in true }
    ) -> FrameWriter {
        FrameWriter(
            gateway: gateway,
            isVisible: visible,
            markStale: { [weak self] space in
                self?.events.append("stale")
                self?.staleMarks.append(space)
            },
            markExpected: { [weak self] id, _ in
                self?.events.append("echo")
                self?.echoed.append(id)
            },
            cancelExpected: { [weak self] id in
                self?.events.append("cancel")
                self?.cancelled.append(id)
            },
            seedBaseline: { [weak self] id, frame in
                self?.baselines.append((id, frame))
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

        let result = makeWriter().write(7, handle: handle, to: target, bounds: Self.bounds, on: canvas, check: .rollback)

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

        let result = makeWriter().write(7, handle: handle, to: frame, bounds: Self.bounds, on: canvas, check: .rollback)

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
            .write(7, handle: handle, to: frame, bounds: Self.bounds, on: canvas, check: .rollback)

        XCTAssertEqual(result, .deferredOffSpace)
        XCTAssertTrue(gateway.writes.isEmpty)
        XCTAssertTrue(echoed.isEmpty)
        XCTAssertTrue(checked.isEmpty)
        XCTAssertEqual(staleMarks, [canvas])
    }

    func testDeferredWriteSeedsTheBaselineTheSwipeBackWillClaim() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let target = CGRect(x: 40, y: 40, width: 300, height: 200)

        let result = makeWriter(visible: { _ in false })
            .write(7, handle: handle, to: target, bounds: Self.bounds, on: canvas, check: .rollback)

        XCTAssertEqual(result, .deferredOffSpace)
        XCTAssertEqual(
            baselines.last?.1, target,
            "the deferral arms no echo, so the diff baseline carries the target instead")
        XCTAssertTrue(echoed.isEmpty, "a deferral never arms an expectation")
    }

    func testExplicitNoneCheckWritesWithoutScheduling() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let target = CGRect(x: 40, y: 40, width: 300, height: 200)

        let result = makeWriter().write(7, handle: handle, to: target, bounds: Self.bounds, on: canvas, check: .none)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 1)
        XCTAssertEqual(echoed, [7])
        XCTAssertTrue(checked.isEmpty)
    }

    func testRefusedWriteCancelsTheEchoAndSeedsTheLiveBaseline() {
        let original = CGRect(x: 0, y: 0, width: 100, height: 100)
        let handle = gateway.addWindow(frame: original)
        gateway.refuseNextWrites(handle)
        let target = CGRect(x: 40, y: 40, width: 300, height: 200)

        let result = makeWriter().write(7, handle: handle, to: target, bounds: Self.bounds, on: canvas, check: .rollback)

        XCTAssertEqual(result, .refused)
        XCTAssertEqual(echoed, [7], "the expectation is armed before the write")
        XCTAssertEqual(cancelled, [7], "a refused write clears the expectation again")
        XCTAssertEqual(
            baselines.last?.0, 7,
            "the refusal reseeds the drag baseline from the live frame")
        XCTAssertEqual(
            baselines.last?.1, original,
            "the baseline is the frame the app still holds, not the refused target")
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

        let result = makeWriter().write(7, handle: handle, to: target, bounds: Self.bounds, on: canvas, check: .rollback)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 2, "the repin is its own write")
        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 1100, y: 0, width: 500, height: 1000),
            "the floor-width window holds the screen edge and simply stops shrinking")
        XCTAssertEqual(
            echoed, [7, 7],
            "the echo re-arms at the frame the window really has, not the one it was refused")
    }

    func testRefusedClampRepairCancelsTheExpectationAndReportsRefused() {
        // The repin is a second expected write, not a side effect. When
        // the app refuses it the window still holds the clamped frame, so
        // the target expectation is cancelled, the drag baseline is reseeded
        // from the frame that actually landed, and the caller is told the
        // write failed instead of trusting the target.
        let handle = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 533, height: 1000))
        gateway.writtenFrame = clampWidthToFloor(500)
        let target = CGRect(x: 1300, y: 0, width: 300, height: 1000)
        let applied = CGRect(x: 1300, y: 0, width: 500, height: 1000)
        var writes = 0
        gateway.willWrite = { [weak self] _ in
            writes += 1
            if writes == 2 {
                self?.gateway.refuseNextWrites(handle)
            }
        }

        let result = makeWriter().write(
            7, handle: handle, to: target, bounds: Self.bounds,
            on: canvas, check: .rollback)

        XCTAssertEqual(result, .refused)
        XCTAssertEqual(gateway.writes.count, 1, "the refused repair did not land")
        XCTAssertEqual(gateway.frame(of: handle), applied)
        XCTAssertEqual(
            echoed, [7],
            "only the target write armed an echo; the refused repair did not")
        XCTAssertEqual(cancelled, [7], "the refused repair cancels the expectation")
        XCTAssertEqual(
            baselines.last?.1, applied,
            "the baseline is the frame the window still holds, not the repin")
        XCTAssertTrue(checked.isEmpty, "a refused write schedules no convergence check")
    }

    func testClampedWriteAnchoredOnTheScreenEdgeIsLeftAlone() {
        // Shrinking from the right: the floor keeps the window's origin,
        // which IS the screen edge, so it stopped shrinking in bounds
        // already and a second write would only fight the app.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 533, height: 1000))
        gateway.writtenFrame = clampWidthToFloor(500)
        let target = CGRect(x: 0, y: 0, width: 300, height: 1000)

        let result = makeWriter().write(7, handle: handle, to: target, bounds: Self.bounds, on: canvas, check: .rollback)

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

        let result = makeWriter().write(7, handle: handle, to: target, bounds: Self.bounds, on: canvas, check: .rollback)

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

        let result = makeWriter().write(7, handle: handle, to: target, bounds: Self.bounds, on: canvas, check: .rollback)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 1)
        XCTAssertEqual(gateway.frame(of: handle), target)
    }
}
