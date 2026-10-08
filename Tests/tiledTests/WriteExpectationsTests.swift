import XCTest
@testable import tiled

/// WriteExpectations through its interface: one frame push's whole life -
/// the shared write policy, the arm/echo/late-verdict trail, the
/// consequence a silent ignore fires, and the intent that outlives the
/// echo entry. Fake gateway, recording ports; no controller, no AX.
final class WriteExpectationsTests: XCTestCase {
    private var expectations: WriteExpectations!
    private var gateway: FakeWindowGateway!
    /// Injectable clock backing the echo timestamps.
    private var now = Date()
    /// Live frames the convergence check reads, by window.
    private var liveFrames: [WindowID: CGRect] = [:]
    /// Late checks captured from the injectable scheduler.
    private var checks: [() -> Void] = []
    /// How many scheduled checks were cancelled.
    private var cancels = 0
    /// Consequences the owner fired on silent ignores.
    private var consequences: [(id: WindowID, consequence: WriteExpectations.Consequence)] = []

    private let canvas = TilingSpaceKey(
        screen: ScreenID(rawValue: 1), space: SpaceID(rawValue: 10))

    override func setUp() {
        super.setUp()
        now = Date()
        liveFrames = [:]
        checks = []
        cancels = 0
        consequences = []
        writeEvents = []
        gateway = FakeWindowGateway()
        expectations = makeExpectations()
    }

    /// The owner under test, with recording ports. The events array the
    /// policy tests read lives in `writeEvents`.
    private var writeEvents: [String] = []

    private func makeExpectations(
        visible: @escaping (TilingSpaceKey) -> Bool = { _ in true }
    ) -> WriteExpectations {
        WriteExpectations(
            gateway: gateway,
            isVisible: visible,
            markStale: { [weak self] _ in self?.writeEvents.append("stale") },
            scheduleCheck: { [weak self] fire in
                guard let self else { return {} }
                self.writeEvents.append("check")
                self.checks.append(fire)
                return { self.cancels += 1 }
            },
            liveFrameOf: { [weak self] in self?.liveFrames[$0] },
            notePushed: { [weak self] _, _ in self?.writeEvents.append("armed") },
            onConsequence: { [weak self] id, consequence in
                self?.consequences.append((id, consequence))
            },
            now: { [weak self] in self?.now ?? Date() })
    }

    /// The standard pushed target every verdict test starts from.
    private let target = CGRect(x: 0, y: 500, width: 840, height: 500)

    // MARK: Write policy

    func testAcceptedWriteArmsThenWritesThenSchedulesTheCheck() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let written = CGRect(x: 40, y: 40, width: 300, height: 200)
        // Order matters: the expectation must exist before the write can
        // echo, and the check is scheduled only after the write landed.
        gateway.writtenFrame = { [weak self] _, target in
            self?.writeEvents.append("write")
            return target
        }

        let result = expectations.write(
            7, handle: handle, to: written, on: canvas, consequence: .slotCommit)

        XCTAssertEqual(result, .written)
        XCTAssertEqual(gateway.writes.count, 1)
        XCTAssertEqual(gateway.writes.first?.0, handle)
        XCTAssertEqual(gateway.writes.first?.1, written)
        XCTAssertEqual(
            writeEvents, ["armed", "write", "check"],
            "arm before the gateway call, schedule only after it landed")
        XCTAssertEqual(
            expectations.classify(7, frame: written), .consumed,
            "the write armed its echo expectation")
        XCTAssertEqual(checks.count, 1)
    }

    func testNoOpTargetIsSkippedWithoutWritingOrArmingAnEcho() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let handle = gateway.addWindow(frame: frame)

        let result = expectations.write(
            7, handle: handle, to: frame, on: canvas, consequence: .slotCommit)

        XCTAssertEqual(result, .skippedNoOp)
        XCTAssertTrue(gateway.writes.isEmpty)
        XCTAssertEqual(
            expectations.classify(7, frame: frame), .live,
            "no expectation was armed")
        XCTAssertTrue(checks.isEmpty)
        XCTAssertEqual(writeEvents, [])
    }

    func testHiddenCanvasDefersBeforeAnyWritePolicyRuns() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let handle = gateway.addWindow(frame: frame)

        // A no-op target proves visibility is judged first: the write
        // defers and the canvas is marked stale instead of skipped.
        let result = makeExpectations(visible: { _ in false }).write(
            7, handle: handle, to: frame, on: canvas, consequence: .slotCommit)

        XCTAssertEqual(result, .deferredOffSpace)
        XCTAssertTrue(gateway.writes.isEmpty)
        XCTAssertEqual(writeEvents, ["stale"])
        XCTAssertTrue(checks.isEmpty)
    }

    func testRefusedWriteArmsTheEchoButSchedulesNoCheck() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        gateway.refuseNextWrites(handle)
        let written = CGRect(x: 40, y: 40, width: 300, height: 200)

        let result = expectations.write(
            7, handle: handle, to: written, on: canvas, consequence: .slotCommit)

        XCTAssertEqual(result, .refused)
        XCTAssertEqual(writeEvents, ["armed"])
        XCTAssertEqual(
            expectations.classify(7, frame: written), .consumed,
            "the refused write had already armed its echo expectation")
        XCTAssertTrue(checks.isEmpty)
    }

    // MARK: The late consequence

    func testSilentIgnoreFiresTheSlotCommitConsequence() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        liveFrames[7] = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        expectations.write(
            7, handle: handle, to: target, on: canvas, consequence: .slotCommit)

        checks[0]()

        XCTAssertEqual(consequences.count, 1)
        XCTAssertEqual(consequences.first?.id, 7)
        XCTAssertEqual(consequences.first?.consequence, .slotCommit)
    }

    func testCoverToggleConsequenceCarriesThePreWriteValue() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let saved = CGRect(x: 120, y: 90, width: 700, height: 500)
        liveFrames[7] = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        expectations.write(
            7, handle: handle, to: target, on: canvas,
            consequence: .coverToggle(revertTo: saved))

        checks[0]()

        XCTAssertEqual(consequences.first?.consequence, .coverToggle(revertTo: saved))
    }

    func testConvergedWriteFiresNoConsequence() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        expectations.write(
            7, handle: handle, to: target, on: canvas, consequence: .slotCommit)
        var echo = target
        echo.origin.x += 10
        XCTAssertEqual(expectations.classify(7, frame: echo), .consumed)

        checks[0]()

        XCTAssertTrue(consequences.isEmpty, "an applied write pays nothing")
    }

    func testNewerWriteSupersedesTheOlderCheck() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let first = CGRect(x: 0, y: 500, width: 840, height: 500)
        let second = CGRect(x: 840, y: 0, width: 760, height: 1000)
        expectations.write(
            7, handle: handle, to: first, on: canvas, consequence: .slotCommit)
        expectations.write(
            7, handle: handle, to: second, on: canvas,
            consequence: .coverToggle(revertTo: nil))

        XCTAssertEqual(cancels, 1, "the newer write cancelled the older check")
        // The superseded closure must judge nothing: its silence is the
        // new write's to answer.
        checks[0]()
        XCTAssertTrue(consequences.isEmpty, "a cancelled check pays nothing")
        // The surviving check judges the surviving write, token included.
        liveFrames[7] = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        checks[1]()
        XCTAssertEqual(consequences.first?.consequence, .coverToggle(revertTo: nil))
    }

    func testForgetCancelsThePendingCheck() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        expectations.write(
            7, handle: handle, to: target, on: canvas, consequence: .slotCommit)

        expectations.forget(7)
        checks[0]()

        XCTAssertEqual(cancels, 1)
        XCTAssertTrue(consequences.isEmpty, "a forgotten window is never judged")
        XCTAssertEqual(expectations.classify(7, frame: target), .live)
    }

    // MARK: Tick verdicts

    func testNoExpectationIsLive() {
        XCTAssertEqual(expectations.classify(1, frame: target), .live)
        XCTAssertNil(expectations.convergence(for: 1))
    }

    func testCloseTickConsumesTheWrite() {
        expectations.noteExpected(1, target)

        var echo = target
        echo.origin.x += 10 // within tolerance on every edge

        XCTAssertEqual(expectations.classify(1, frame: echo), .consumed)
        XCTAssertEqual(
            expectations.convergence(for: 1), .converged,
            "the consume settles the entry the late check reads")
    }

    func testCloseTickAfterConvergenceSettles() {
        expectations.noteExpected(1, target)
        var echo = target
        echo.origin.x += 10
        XCTAssertEqual(expectations.classify(1, frame: echo), .consumed)

        // The animation tail: close again, already settled.
        var tail = target
        tail.size.width -= 8
        XCTAssertEqual(expectations.classify(1, frame: tail), .settling)
    }

    func testCloseTickPastTheSettleWindowExpires() {
        expectations.noteExpected(1, target)
        var echo = target
        echo.origin.x += 10
        XCTAssertEqual(expectations.classify(1, frame: echo), .consumed)

        now += TimeInterval(2) // past settleWindow (1s)
        XCTAssertEqual(expectations.classify(1, frame: echo), .settleExpired)
        XCTAssertNil(expectations.convergence(for: 1), "the expired entry is gone")
        XCTAssertEqual(
            expectations.classify(1, frame: echo), .live,
            "the next tick processes fully live")
    }

    func testSettledTickLeavingTheRadiusEndsSettling() {
        expectations.noteExpected(1, target)
        var echo = target
        echo.origin.x += 10
        XCTAssertEqual(expectations.classify(1, frame: echo), .consumed)

        var far = target
        far.size.height -= 100 // top edge out of the echo radius
        XCTAssertEqual(expectations.classify(1, frame: far), .settleEnd)
        XCTAssertNil(expectations.convergence(for: 1), "the entry is gone")
        XCTAssertEqual(expectations.classify(1, frame: far), .live)
    }

    func testConvergingTickIsSwallowed() {
        expectations.noteExpected(1, target)

        var drifting = target
        drifting.origin.x += 100
        XCTAssertEqual(expectations.classify(1, frame: drifting), .converging)
        XCTAssertNil(
            expectations.convergence(for: 1),
            "frames arrived but never settled: no verdict either way")
    }

    func testFasterDivergenceEscapes() {
        expectations.noteExpected(1, target)
        var first = target
        first.origin.x += 100
        XCTAssertEqual(expectations.classify(1, frame: first), .converging)

        var second = target
        second.origin.x += 200
        XCTAssertEqual(expectations.classify(1, frame: second), .escape)
        XCTAssertEqual(expectations.classify(1, frame: second), .live)
    }

    func testUnappliedWriteGoesStale() {
        expectations.noteExpected(1, target)

        now += TimeInterval(4) // past staleWrite (3s)
        var drifting = target
        drifting.origin.x += 100
        XCTAssertEqual(expectations.classify(1, frame: drifting), .stale)
        XCTAssertEqual(expectations.classify(1, frame: drifting), .live)
    }

    // MARK: Late convergence

    func testConvergenceVerdictReadsTheEchoTrail() {
        // No entry (consumed, then expired): inconclusive.
        expectations.noteExpected(1, target)
        XCTAssertEqual(expectations.classify(1, frame: target), .consumed)
        now += TimeInterval(5)
        XCTAssertEqual(expectations.classify(1, frame: target), .settleExpired)
        XCTAssertNil(expectations.convergence(for: 1), "consumed entry: inconclusive")

        // Total silence with an answerable live frame far from target:
        // ignored - the write never took effect.
        let ignoring = makeExpectations()
        let topRight = CGRect(x: 840, y: 500, width: 840, height: 500)
        liveFrames[2] = CGRect(x: 4000, y: 4000, width: 840, height: 500)
        ignoring.noteExpected(2, topRight)
        XCTAssertEqual(ignoring.convergence(for: 2), .ignored)

        // Total silence with an UNREADABLE live frame: inconclusive.
        // During a lid close/open the frame read fails for live windows;
        // judging that as ignored rolled fresh placements back
        // (observed on live AX).
        expectations.noteExpected(4, target)
        XCTAssertNil(
            expectations.convergence(for: 4),
            "an unreadable live frame is can't-judge, not ignored")

        // A converging tick settles the entry: converged.
        let bottomLeft = CGRect(x: 0, y: 0, width: 840, height: 500)
        expectations.noteExpected(3, bottomLeft)
        var echo = bottomLeft
        echo.origin.x += 10
        XCTAssertEqual(expectations.classify(3, frame: echo), .consumed)
        XCTAssertEqual(expectations.convergence(for: 3), .converged)

        // Frames that never approach the target: inconclusive (alive,
        // leave it alone); the controller compares live frames.
        expectations.noteExpected(4, target)
        XCTAssertEqual(
            expectations.classify(4, frame: CGRect(x: 0, y: 0, width: 840, height: 300)),
            .converging)
        XCTAssertNil(expectations.convergence(for: 4))
    }

    func testSilentConvergenceChecksTheLiveFrameBeforeCallingItIgnored() {
        // Total echo silence is not automatically a silent ignore: apps
        // that round frames to an internal grid can absorb a write whose
        // target sits within their rounding distance, emitting no
        // notification. The live frame is the tiebreaker: within the
        // echo tolerance of the target means converged; far from it
        // means genuinely ignored.
        // Silent but at target: converged, and the entry is cleared.
        expectations.noteExpected(1, target)
        liveFrames[1] = CGRect(x: 5, y: 505, width: 840, height: 500)
        XCTAssertEqual(
            expectations.convergence(for: 1), .converged,
            "the live frame sits within tolerance of the target")
        XCTAssertNil(
            expectations.convergence(for: 1),
            "the entry is consumed by the convergence win")

        // Silent and far from target: the write never took effect.
        let farTarget = CGRect(x: 840, y: 500, width: 840, height: 500)
        expectations.noteExpected(2, farTarget)
        liveFrames[2] = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(expectations.convergence(for: 2), .ignored)
    }

    // MARK: Intent

    func testNoteExpectedRecordsIntent() {
        expectations.noteExpected(1, target)
        XCTAssertEqual(expectations.intent(for: 1), target)
    }

    func testNoteIntentRecordsIntentWithoutArmingAnExpectation() {
        expectations.noteIntent(1, target)

        XCTAssertEqual(
            expectations.intent(for: 1), target,
            "the intent is recorded without a write")
        XCTAssertEqual(
            expectations.classify(1, frame: target), .live,
            "no write happened: nothing swallows the tick")
        XCTAssertNil(expectations.convergence(for: 1))
    }

    func testIntentSurvivesForget() {
        expectations.noteExpected(1, target)
        expectations.forget(1)
        XCTAssertEqual(
            expectations.intent(for: 1), target,
            "undo chapters replay writes for ids whose frames were restored out from under them")
    }

    func testForgetClearsTheEchoEntry() {
        expectations.noteExpected(1, target)
        expectations.forget(1)
        XCTAssertEqual(expectations.classify(1, frame: target), .live)
        XCTAssertNil(expectations.convergence(for: 1))
    }

    // MARK: No-op skip (through the drag loop)

    func testNoOpWriteIsSkippedInsteadOfRecordingIntent() {
        // A write whose target sits within noOpWriteTolerance (1pt) of the
        // window's live frame is a no-op: pushing it would echo nothing,
        // and the late convergence check would read that silence as a
        // silent ignore and evict an already-correct window. So the rect
        // is dropped and no new intent is recorded.
        var liveFrames: [WindowID: CGRect] = [:]
        var slots: [WindowID: Slot] = [:]
        var handles: [WindowID: WindowHandle] = [:]
        var occupants: [Slot: WindowID] = [:]
        var pushed: [(rects: [WindowID: CGRect], excluding: WindowID?)] = []
        let gateway = FakeWindowGateway()
        let tracker = DragTracker(
            expectations: expectations,
            context: DragTracker.Context(
                slotOf: { slots[$0] },
                frameOf: { handles[$0].flatMap { gateway.frame(of: $0) } },
                boundsOf: { $0 },
                occupants: { occupants },
                liveFrameOf: { liveFrames[$0] }),
            gridProvider: DragTracker.GridProvider(
                grid: { _ in GridLayout() },
                setGrid: { _, _ in }),
            apply: { rects, excluding in pushed.append((rects, excluding)) },
            scheduleDragEnd: { _ in {} })
        // Window 1's live frame (0,500,840,500) is its own bounds; the
        // topLeft rect under the default grid is (0,750,420,250).
        handles[1] = gateway.addWindow(frame: target)
        slots[1] = .topLeft
        occupants[.topLeft] = 1
        expectations.noteExpected(1, target)
        liveFrames[1] = CGRect(x: 0, y: 750.5, width: 420, height: 249.5)

        tracker.reassertAll(occupants: occupants)
        let expectation = XCTestExpectation(description: "no-op write skipped")
        DispatchQueue.main.async {
            XCTAssertNil(
                pushed.first?.rects[1], "no rect for window 1 in any push")
            XCTAssertEqual(
                self.expectations.intent(for: 1), self.target,
                "the skipped write records no new intent: the tile-frame intent survives")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Control: the same reassert with the live frame far from the
        // target pushes and records intent; the skip is the live frame's
        // doing, not the reassert's.
        liveFrames[1] = CGRect(x: 600, y: 100, width: 50, height: 50)
        tracker.reassertAll(occupants: occupants)
        let pushedExpectation = XCTestExpectation(description: "real write pushed")
        DispatchQueue.main.async {
            let slotRect = CGRect(x: 0, y: 750, width: 420, height: 250)
            XCTAssertEqual(pushed.last?.rects[1], slotRect)
            XCTAssertEqual(
                self.expectations.intent(for: 1), slotRect,
                "a real push records intent")
            pushedExpectation.fulfill()
        }
        wait(for: [pushedExpectation], timeout: 1.0)
    }
}
