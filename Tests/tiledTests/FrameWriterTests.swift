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
}
