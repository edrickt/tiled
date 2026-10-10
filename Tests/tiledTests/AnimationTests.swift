import CoreGraphics
import XCTest
@testable import tiled

/// Tiled-driven animation through `TilingSpaceHarness`: the harness's
/// injected clock and scheduler let tests fire each ~60Hz step by hand
/// and assert the fake gateway's write log. No runloop, no AX.
final class AnimationTests: XCTestCase {
    private var harness: TilingSpaceHarness!

    override func setUp() {
        super.setUp()
        harness = TilingSpaceHarness()
        harness.animationEnabled = true
    }

    /// Sum of per-edge deltas, the animator's monotonicity metric.
    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.maxX - b.maxX)
            + abs(a.minY - b.minY) + abs(a.maxY - b.maxY)
    }

    // MARK: The first glide

    func testTileGlidesInMonotoneStepsEndingExactlyOnTheSlot() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let handle = harness.handle(of: id)!
        let target = harness.rect(.topLeft)

        harness.apply(slot: .topLeft, requester: id)

        XCTAssertEqual(harness.gateway.writes.count, 1, "the first step is synchronous")
        XCTAssertEqual(harness.gateway.writes[0].handle, handle)
        XCTAssertTrue(harness.hasPendingSteps, "the remaining steps are scheduled")
        // The first step's frame pins the spec's motion: cubic ease-out at
        // 180ms with the first step one 60Hz tick in (t = 0.0926, eased
        // 0.25285). Literals derived from the spec, not recomputed here.
        let first = harness.gateway.writes[0].frame
        XCTAssertEqual(first.origin.x, 149.43, accuracy: 0.05)
        XCTAssertEqual(first.origin.y, 301.14, accuracy: 0.05)
        XCTAssertEqual(first.width, 501.14, accuracy: 0.05)
        XCTAssertEqual(first.height, 375.86, accuracy: 0.05)
        XCTAssertNotEqual(first, target)

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: id), target, "the glide ends exactly on the slot rect")
        XCTAssertFalse(harness.hasPendingSteps)
        let frames = harness.gateway.writes.map(\.frame)
        XCTAssertGreaterThan(frames.count, 2, "more than a first and final frame")
        // Monotone toward the target: every step moves closer, none past.
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(
                distance(next, target), distance(previous, target),
                "step \(next) must not move away from \(target)")
        }
        XCTAssertEqual(frames.last, target, "the last written frame is the exact target")
    }

    func testMultiWindowChangeGlidesEveryWindowInParallel() {
        let a = harness.addWindow(frame: CGRect(x: 100, y: 100, width: 300, height: 300))
        let b = harness.addWindow(frame: CGRect(x: 900, y: 100, width: 300, height: 300))
        harness.apply(slot: .topLeft, requester: a)
        harness.settleAnimations()
        harness.apply(slot: .topRight, requester: b)
        harness.settleAnimations()
        let aTarget = harness.rect(.topRight)
        let bTarget = harness.rect(.topLeft)
        harness.gateway.clearWrites()

        // A tiled requester swapping with the window in its target slot:
        // both windows move in the one change.
        harness.apply(slot: .topRight, requester: a)

        XCTAssertEqual(
            harness.gateway.writes.count, 2,
            "both glides write their first step synchronously")
        XCTAssertNotEqual(harness.frame(of: a), aTarget)
        XCTAssertNotEqual(harness.frame(of: b), bTarget)

        harness.step()
        harness.step()
        XCTAssertEqual(
            harness.gateway.writes.count, 4,
            "one more step for each window: the glides run in parallel")

        harness.settleAnimations()
        XCTAssertEqual(harness.frame(of: a), aTarget)
        XCTAssertEqual(harness.frame(of: b), bTarget)
    }

    // MARK: Retarget

    func testSecondRequestMidGlideRetargetsFromTheCurrentFrame() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let abandoned = harness.rect(.topLeft)
        let retargeted = harness.rect(.bottomRight)

        harness.apply(slot: .topLeft, requester: id)
        harness.step()
        harness.step()
        let before = harness.frame(of: id)!
        let writesBefore = harness.gateway.writes.count

        harness.apply(slot: .bottomRight, requester: id)

        // Motion continues from the current frame: the new glide's first
        // step is a fraction of the way from where the window already is,
        // never a jump to the abandoned target or the new one.
        let resumed = harness.gateway.writes[writesBefore].frame
        XCTAssertLessThanOrEqual(
            distance(before, resumed), distance(before, retargeted) * 0.3,
            "the retarget resumes from the window's current frame")
        XCTAssertGreaterThan(distance(before, resumed), 0)

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: id), retargeted)
        XCTAssertFalse(
            harness.gateway.writes.dropFirst(writesBefore).contains { $0.frame == abandoned },
            "the abandoned target is never written after supersession")
    }

    // MARK: Hand takeover

    func testTitleBarGrabMidGlideCancelsWithoutLandingTheTarget() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let handle = harness.handle(of: id)!
        let target = harness.rect(.topLeft)

        harness.apply(slot: .topLeft, requester: id)
        harness.step()
        harness.step()
        let writesBeforeGrab = harness.gateway.writes.count

        // The user grabs the title bar: a pure-origin move, size held.
        let grabbed = harness.frame(of: id)!.offsetBy(dx: 80, dy: 40)
        harness.gateway.simulateChange(handle, to: grabbed)

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: id), grabbed, "the hand owns the frame")
        XCTAssertEqual(
            harness.gateway.writes.count, writesBeforeGrab,
            "the glide cancels: no further steps, no final write")
        XCTAssertFalse(
            harness.gateway.writes.contains { $0.frame == target },
            "the abandoned target never lands")
    }

    // MARK: Restores

    func testUntileGlidesBackToItsPreTileFrame() {
        let original = CGRect(x: 200, y: 200, width: 400, height: 300)
        let id = harness.addWindow(frame: original)
        harness.apply(slot: .topLeft, requester: id)
        harness.settleAnimations()
        XCTAssertEqual(harness.frame(of: id), harness.rect(.topLeft))
        harness.gateway.clearWrites()

        harness.space.untile(window: id, reflowing: true, context: harness.context())

        XCTAssertEqual(harness.gateway.writes.count, 1, "the first step is synchronous")
        XCTAssertEqual(harness.gateway.writes[0].handle, harness.handle(of: id))
        XCTAssertNotEqual(
            harness.frame(of: id), original,
            "the window is mid-glide, not back yet")
        XCTAssertTrue(harness.hasPendingSteps)

        harness.settleAnimations()

        XCTAssertEqual(
            harness.frame(of: id), original,
            "the glide lands exactly on the pre-tile frame")
        XCTAssertEqual(
            harness.gateway.writes.last?.frame, original,
            "the landing writes the exact pre-tile frame")
        XCTAssertFalse(harness.hasPendingSteps)
    }

    func testUntileMidTileGlideSupersedesTheAbandonedTile() {
        let original = CGRect(x: 200, y: 200, width: 400, height: 300)
        let id = harness.addWindow(frame: original)
        let slot = harness.rect(.topLeft)

        harness.apply(slot: .topLeft, requester: id)
        harness.step()
        harness.step()
        let writesBeforeRestore = harness.gateway.writes.count

        harness.space.untile(window: id, reflowing: false, context: harness.context())

        XCTAssertEqual(
            harness.gateway.writes.count, writesBeforeRestore + 1,
            "the restore starts its own glide from the current frame")

        harness.settleAnimations()

        XCTAssertEqual(
            harness.frame(of: id), original,
            "the restore glide lands on the pre-tile frame")
        XCTAssertFalse(
            harness.gateway.writes.dropFirst(writesBeforeRestore).contains { $0.frame == slot },
            "the abandoned tile target is never written after supersession")
    }

    func testReTileAfterRestoreSupersedesTheRestoreGlide() {
        let original = CGRect(x: 200, y: 200, width: 400, height: 300)
        let id = harness.addWindow(frame: original)
        harness.apply(slot: .topLeft, requester: id)
        harness.settleAnimations()

        harness.space.untile(window: id, reflowing: false, context: harness.context())

        // A rapid next hotkey hands the same released window back to the
        // canvas under a fresh id: one window, two glides. The newest
        // target must supersede the in-flight restore glide. No
        // intermediate fire: both glides sit on the same step generation.
        let fresh = harness.reattach(id)
        harness.apply(slot: .topLeft, requester: fresh)
        harness.gateway.clearWrites()

        harness.step()
        harness.step()

        XCTAssertEqual(
            harness.gateway.writes.count, 1,
            "only the newest glide steps; the abandoned restore glide is superseded")
        XCTAssertEqual(
            harness.gateway.writes.last?.handle, harness.handle(of: id),
            "the stepping glide drives the re-attached window")

        harness.settleAnimations()
        XCTAssertEqual(
            harness.frame(of: id), harness.rect(.topLeft),
            "the newest target lands last")
    }

    func testInstantRestoreSupersedesAnInFlightGlide() {
        let original = CGRect(x: 200, y: 200, width: 400, height: 300)
        let id = harness.addWindow(frame: original)
        harness.apply(slot: .topLeft, requester: id)
        harness.step()

        // Reduce Motion turns on (or the toggle flips off) mid-glide while
        // the tile glide is still in flight: the restore snaps. The stale
        // glide must not keep stepping toward the tile and overwrite the
        // frame the user just released.
        harness.animationEnabled = false
        harness.space.untile(window: id, reflowing: false, context: harness.context())

        XCTAssertEqual(harness.frame(of: id), original, "the snap lands instantly")
        XCTAssertEqual(harness.gateway.writes.last?.frame, original)

        harness.settleAnimations()

        XCTAssertEqual(
            harness.frame(of: id), original,
            "the cancelled tile glide never overwrites the release")
    }

    func testUntileAllChaptersTheFramesTheGlidesAreHeadedTo() {
        let aOriginal = CGRect(x: 100, y: 100, width: 300, height: 200)
        let bOriginal = CGRect(x: 900, y: 50, width: 500, height: 400)
        let a = harness.addWindow(frame: aOriginal)
        let b = harness.addWindow(frame: bOriginal)
        harness.apply(slot: .topLeft, requester: a)
        harness.settleAnimations()
        harness.apply(slot: .topRight, requester: b)
        harness.settleAnimations()
        harness.gateway.clearWrites()

        harness.space.untileAll(context: harness.context())

        // The chapter records where each window is going, not where a
        // mid-glide read happens to catch it: a later untile restores the
        // same pre-tile frames the user gave the windows.
        let chapter = harness.space.undoStack.last?.snapshot ?? []
        XCTAssertEqual(chapter.count, 2)
        XCTAssertEqual(
            chapter.first { $0.handle == harness.handle(of: a) }?.preTileFrame,
            aOriginal)
        XCTAssertEqual(
            chapter.first { $0.handle == harness.handle(of: b) }?.preTileFrame,
            bOriginal)
    }

    func testUntileAllGlidesEveryRestoredWindowInParallel() {
        let aOriginal = CGRect(x: 100, y: 100, width: 300, height: 200)
        let bOriginal = CGRect(x: 900, y: 50, width: 500, height: 400)
        let a = harness.addWindow(frame: aOriginal)
        let b = harness.addWindow(frame: bOriginal)
        harness.apply(slot: .topLeft, requester: a)
        harness.settleAnimations()
        harness.apply(slot: .topRight, requester: b)
        harness.settleAnimations()
        harness.gateway.clearWrites()

        harness.space.untileAll(context: harness.context())

        XCTAssertEqual(
            harness.gateway.writes.count, 2,
            "both restores write their first step synchronously")
        XCTAssertNotEqual(harness.frame(of: a), aOriginal, "a is mid-glide")
        XCTAssertNotEqual(harness.frame(of: b), bOriginal, "b is mid-glide")

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: a), aOriginal, "each glide lands on its own pre-tile frame")
        XCTAssertEqual(harness.frame(of: b), bOriginal)
        XCTAssertFalse(harness.hasPendingSteps)
    }

    func testLayoutSwitchGlidesEveryRestoredWindowInParallel() {
        let aOriginal = CGRect(x: 200, y: 200, width: 400, height: 300)
        let bOriginal = CGRect(x: 900, y: 100, width: 300, height: 300)
        let a = harness.addWindow(frame: aOriginal)
        let b = harness.addWindow(frame: bOriginal)
        harness.apply(slot: .topLeft, requester: a)
        harness.settleAnimations()
        harness.apply(slot: .topRight, requester: b)
        harness.settleAnimations()
        harness.gateway.clearWrites()

        // A sixths request switches the layout: b is restored while a
        // moves into the new slot. Both glide in the one change.
        harness.apply(slot: .sixthTopLeft, requester: a)

        XCTAssertEqual(
            harness.gateway.writes.count, 2,
            "the restore and the requester's move write together")
        XCTAssertNotEqual(harness.frame(of: b), bOriginal)
        XCTAssertNotEqual(harness.frame(of: a), harness.rect(.sixthTopLeft))

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: b), bOriginal, "the evicted window lands on its pre-tile frame")
        XCTAssertEqual(harness.frame(of: a), harness.rect(.sixthTopLeft))
        XCTAssertFalse(harness.hasPendingSteps)
    }

    func testUndoGlidesTheChaptersWindowsBack() {
        let aOriginal = CGRect(x: 200, y: 200, width: 400, height: 300)
        let bOriginal = CGRect(x: 900, y: 100, width: 300, height: 300)
        let a = harness.addWindow(frame: aOriginal)
        let b = harness.addWindow(frame: bOriginal)
        harness.apply(slot: .topLeft, requester: a)
        harness.settleAnimations()
        // b (untiled until now) takes a's slot: a is evicted, b places.
        // One chapter covers the eviction and holds b as requester.
        harness.apply(slot: .topLeft, requester: b)
        harness.settleAnimations()
        guard let snapshot = harness.space.undoStack.last?.snapshot else {
            return XCTFail("the displacement should snapshot")
        }
        XCTAssertEqual(snapshot.count, 1, "only a was evicted")
        harness.gateway.clearWrites()

        // The coordinator's undo pass: the requester restores to its
        // pre-tile frame, then the chapter's evictee retiles into its old
        // slot. Both moves glide in parallel.
        harness.space.restore(window: b, context: harness.context(), animated: true)
        let result = harness.undo(snapshot: snapshot, requester: nil)

        XCTAssertEqual(
            harness.gateway.writes.count, 2,
            "the requester's restore and the evictee's retile write together")
        XCTAssertNotEqual(harness.frame(of: b), bOriginal)
        XCTAssertNotEqual(harness.frame(of: a), harness.rect(.topLeft))

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: b), bOriginal, "the requester glides back to its pre-tile frame")
        XCTAssertEqual(harness.frame(of: a), harness.rect(.topLeft), "the evictee glides back into its slot")
        XCTAssertEqual(result.notice, "Undid displacement \u{00B7} 1 window restored.")
        XCTAssertFalse(harness.hasPendingSteps)
    }

    func testHandOnARestoredWindowMidGlideWins() {
        let original = CGRect(x: 200, y: 200, width: 400, height: 300)
        let id = harness.addWindow(frame: original)
        let handle = harness.handle(of: id)!
        harness.apply(slot: .topLeft, requester: id)
        harness.settleAnimations()
        harness.gateway.clearWrites()

        // The restore glide is in flight; the window is no longer echo
        // tracked (its record is gone), so the animator's per-step
        // read-back is the only hand detector.
        harness.space.untile(window: id, reflowing: false, context: harness.context())
        harness.step()
        let writesBeforeGrab = harness.gateway.writes.count

        let grabbed = harness.frame(of: id)!.offsetBy(dx: 80, dy: 40)
        harness.gateway.simulateChange(handle, to: grabbed)

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: id), grabbed, "the hand owns the frame")
        XCTAssertEqual(
            harness.gateway.writes.count, writesBeforeGrab,
            "the glide cancels: no further steps, no landing")
        XCTAssertFalse(
            harness.gateway.writes.contains { $0.frame == original },
            "the abandoned pre-tile target never lands")
    }

    // MARK: Release paths

    func testDragOutSnapBackGlidesIntoTheTile() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let handle = harness.handle(of: id)!
        harness.apply(slot: .topLeft, requester: id)
        harness.settleAnimations()
        let slot = harness.rect(.topLeft)
        harness.gateway.clearWrites()

        // A hand drag on the title bar: origin-only ticks, size held.
        // Echo tracking is cleared first, so the ticks read as the hand.
        harness.tracker.forget(id)
        var dragged = harness.frame(of: id)!
        for _ in 0..<2 {
            dragged = dragged.offsetBy(dx: 20, dy: 15)
            harness.gateway.simulateSilentChange(handle, to: dragged)
            harness.tracker.handleChange(id: id, frame: dragged)
        }

        // The button lifts short of the untile distance: the tracker
        // schedules the snap-back push for the next runloop tick.
        harness.fireDragEnd()
        let pushed = expectation(description: "snap-back push")
        DispatchQueue.main.async { pushed.fulfill() }
        wait(for: [pushed], timeout: 1.0)

        XCTAssertEqual(
            harness.gateway.writes.count, 1,
            "the snap-back glides: one synchronous first step")
        XCTAssertNotEqual(harness.frame(of: id), slot, "the window is mid-glide")
        XCTAssertTrue(harness.hasPendingSteps)

        harness.settleAnimations()

        XCTAssertEqual(
            harness.frame(of: id), slot,
            "the glide lands exactly on the slot rect")
        XCTAssertFalse(harness.hasPendingSteps)
    }

    func testMouseUpNeighborCommitGlidesAndTheDraggedWindowHoldsStill() {
        let top = harness.addWindow(frame: CGRect(x: 100, y: 100, width: 400, height: 400))
        let bottom = harness.addWindow(frame: CGRect(x: 100, y: 700, width: 400, height: 400))
        harness.apply(slot: .topLeft, requester: top)
        harness.settleAnimations()
        harness.apply(slot: .bottomLeft, requester: bottom)
        harness.settleAnimations()
        harness.gateway.clearWrites()

        // A hand drag on bottom's top edge (the row splitter): the
        // splitter commits live, the neighbor re-push waits for the lift.
        harness.tracker.forget(bottom)
        harness.tracker.handleChange(id: bottom, frame: harness.frame(of: bottom)!)
        var dragged = harness.frame(of: bottom)!
        dragged.size.height -= 200
        harness.gateway.simulateSilentChange(harness.handle(of: bottom)!, to: dragged)
        harness.tracker.handleChange(id: bottom, frame: dragged)

        harness.tracker.mouseLifted()
        let pushed = expectation(description: "neighbor commit push")
        DispatchQueue.main.async { pushed.fulfill() }
        wait(for: [pushed], timeout: 1.0)

        XCTAssertEqual(harness.gateway.writes.count, 1, "only the neighbor glides")
        XCTAssertEqual(harness.gateway.writes.last?.handle, harness.handle(of: top))
        XCTAssertEqual(
            harness.frame(of: bottom), dragged,
            "the dragged window is not re-pushed: it holds the hand's frame")
        let topTarget = harness.rect(.topLeft)
        XCTAssertNotEqual(harness.frame(of: top), topTarget, "the neighbor is mid-glide")

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: top), topTarget, "the neighbor lands on its new rect")
    }

    // MARK: Graceful surrender

    /// Scripts a natively animating app: every accepted write moves the
    /// window only a tenth of the way to the requested frame, so the
    /// observed frame persistently trails the step schedule instead of
    /// tracking it (an app smoothing its own resize). Returns a reader
    /// for every frame Tiled asked for, in order: the applied frame is
    /// the fake's business, but what Tiled wrote is the contract.
    private func simulateLaggingApp(on handle: WindowHandle) -> () -> [CGRect] {
        let damping: CGFloat = 0.1
        var requests: [CGRect] = []
        harness.gateway.writtenFrame = {
            [weak gateway = harness.gateway] written, target in
            guard written == handle, let current = gateway?.frame(of: written) else {
                return target
            }
            requests.append(target)
            return CGRect(
                x: current.minX + (target.minX - current.minX) * damping,
                y: current.minY + (target.minY - current.minY) * damping,
                width: current.width + (target.width - current.width) * damping,
                height: current.height + (target.height - current.height) * damping)
        }
        return { requests }
    }

    func testLaggingAppSurrendersAndLandsTheTargetEarly() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let target = harness.rect(.topLeft)
        let requests = simulateLaggingApp(on: harness.handle(of: id)!)

        harness.apply(slot: .topLeft, requester: id)

        XCTAssertTrue(harness.hasPendingSteps, "the glide starts")
        harness.settleAnimations()

        let asked = requests()
        XCTAssertFalse(harness.hasPendingSteps, "surrender stops stepping")
        XCTAssertEqual(
            asked.last, target,
            "the surrender lands the exact target for the app's animation to finish on")
        XCTAssertLessThan(
            asked.count, 6,
            "the lag streak surrenders well before the 180ms schedule would land")

        // The glide is over: firing the clock changes nothing.
        let writes = harness.gateway.writes.count
        harness.step()
        harness.step()
        XCTAssertEqual(harness.gateway.writes.count, writes)
    }

    func testRepeatedStepRefusalsSurrenderAndLandTheTarget() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let handle = harness.handle(of: id)!
        let target = harness.rect(.topLeft)

        harness.apply(slot: .topLeft, requester: id)
        XCTAssertTrue(harness.hasPendingSteps, "the first step is accepted")

        // The app refuses the next three step writes, then accepts again:
        // the landing itself must be the write that gets through.
        harness.gateway.refuseNextWrites(handle, count: 3)
        for _ in 0..<4 { harness.step() }

        XCTAssertFalse(
            harness.hasPendingSteps,
            "three refused steps surrender instead of stepping forever")
        XCTAssertEqual(
            harness.frame(of: id), target,
            "the surrender landing writes the exact target and it lands")
        XCTAssertNil(harness.space.error, "the refusal path is not entered: the landing lands")
        XCTAssertEqual(harness.space.state.slot(of: id), .topLeft, "the tile stands")
    }

    func testSurrenderIsPerWindowAndTheOtherWindowKeepsGliding() {
        let aOriginal = CGRect(x: 100, y: 100, width: 400, height: 300)
        let bOriginal = CGRect(x: 900, y: 100, width: 400, height: 300)
        let a = harness.addWindow(frame: aOriginal)
        let b = harness.addWindow(frame: bOriginal)
        harness.apply(slot: .topLeft, requester: a)
        harness.settleAnimations()
        harness.apply(slot: .topRight, requester: b)
        harness.settleAnimations()
        let aTarget = harness.rect(.sixthTopLeft)
        harness.gateway.clearWrites()

        // Only b's app animates natively. Every frame in this change
        // resizes, so the damping moves edges, never the hand's
        // pure-origin shape.
        let requests = simulateLaggingApp(on: harness.handle(of: b)!)

        // A sixths request switches the layout: b is restored to its
        // pre-tile frame while a moves into the requested sixth.
        harness.apply(slot: .sixthTopLeft, requester: a)
        for _ in 0..<3 { harness.step() }

        XCTAssertEqual(
            requests().last, bOriginal,
            "the lagging window surrenders onto its target")
        XCTAssertTrue(
            harness.hasPendingSteps,
            "the windows are independent: a's glide is still stepping")
        XCTAssertNotEqual(harness.frame(of: a), aTarget, "a is still mid-glide")

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: a), aTarget, "a lands on its own target")
        XCTAssertEqual(harness.space.state.slot(of: a), .sixthTopLeft)
        XCTAssertNil(harness.space.state.slot(of: b))
        XCTAssertFalse(harness.hasPendingSteps)
    }

    func testWindowTrackingItsScheduleDoesNotSurrender() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let target = harness.rect(.topLeft)
        var requests: [CGRect] = []
        harness.gateway.writtenFrame = { _, requested in
            requests.append(requested)
            return requested
        }

        harness.apply(slot: .topLeft, requester: id)
        for _ in 0..<4 { harness.step() }

        // The app applies every write, so the read-back is always the
        // frame the last step asked for: tracking, not lagging. Four
        // steps is far enough for a lag check that compared against the
        // current expected step to have surrendered: a tracking window
        // must still be mid-glide, its target unlanded.
        XCTAssertTrue(harness.hasPendingSteps, "a tracking window keeps stepping")
        XCTAssertNotEqual(harness.frame(of: id), target, "still mid-glide")
        XCTAssertFalse(
            requests.contains(target),
            "the target is not landed early: the schedule runs its course")

        harness.settleAnimations()

        XCTAssertEqual(harness.frame(of: id), target, "the natural landing reaches the target")
        XCTAssertEqual(requests.last, target, "the last request is the end-of-glide landing")
    }

    func testSurrenderedLandingRefusedRollsBackThroughTheStandardPath() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let handle = harness.handle(of: id)!

        harness.apply(slot: .topLeft, requester: id)
        XCTAssertTrue(harness.hasPendingSteps, "the first step is accepted")

        // The app refuses the three step writes and the landing: repeated
        // refusals surrender, and the surrendered landing is refused in
        // turn, so the standard rollback runs rather than leaving a
        // silent off-target window.
        harness.gateway.refuseNextWrites(handle, count: 4)
        for _ in 0..<4 { harness.step() }

        XCTAssertNil(harness.space.state.slot(of: id), "the refused landing rolls back")
        XCTAssertNil(harness.space.records[id])
        XCTAssertEqual(
            harness.space.error,
            "TestApp couldn't be tiled: the app refused to resize it.",
            "the standard refusal wording lands on the canvas")
        XCTAssertNotEqual(harness.frame(of: id), harness.rect(.topLeft))
        XCTAssertFalse(harness.hasPendingSteps)
    }

    // MARK: Reduce Motion

    func testReduceMotionSnapsAndIsReadLive() {
        harness.reduceMotion = true
        let first = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let firstTarget = harness.rect(.topLeft)

        harness.apply(slot: .topLeft, requester: first)

        XCTAssertEqual(harness.gateway.writes.count, 1, "Reduce Motion writes instantly")
        XCTAssertEqual(harness.frame(of: first), firstTarget)
        XCTAssertFalse(harness.hasPendingSteps)

        // Read live, not cached: flipping it off animates the next move.
        harness.reduceMotion = false
        let second = harness.addWindow(frame: CGRect(x: 300, y: 100, width: 400, height: 300))
        let secondTarget = harness.rect(.topRight)

        harness.apply(slot: .topRight, requester: second)

        XCTAssertEqual(harness.gateway.writes.count, 2)
        XCTAssertNotEqual(harness.frame(of: second), secondTarget)
        harness.settleAnimations()
        XCTAssertEqual(harness.frame(of: second), secondTarget)
    }

    // MARK: Refusal and landing

    func testRefusedFirstStepRollsBackAndReports() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        let original = harness.frame(of: id)!
        harness.gateway.refuseNextWrites(harness.handle(of: id)!)

        let outcome = harness.apply(slot: .topLeft, requester: id)

        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
        XCTAssertNil(harness.space.state.slot(of: id), "occupancy rolled back")
        XCTAssertNotNil(harness.space.error, "the standard refusal notice lands")
        XCTAssertEqual(harness.frame(of: id), original)
        XCTAssertFalse(harness.hasPendingSteps, "a refused first step never starts a glide")
    }

    func testFinalLandingRepinsAMinSizeAppInsideItsBounds() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 0, width: 1000, height: 1200))
        // The probed minimum-size shape: position lands, width snaps to
        // the app's floor and grows away from the origin.
        harness.gateway.writtenFrame = { _, target in
            CGRect(
                x: target.minX, y: target.minY,
                width: max(target.width, 900), height: target.height)
        }
        // The right half of the injected 1600x1200 bounds.
        harness.apply(slot: .rightHalf, requester: id)
        harness.settleAnimations()

        let landed = harness.frame(of: id)!
        XCTAssertEqual(
            landed, CGRect(x: 700, y: 0, width: 900, height: 1200),
            "the final landing keeps the minimum-size clamp repin")
        XCTAssertLessThanOrEqual(
            landed.maxX, harness.bounds.maxX, "the floor-width window stops at the screen edge")
        XCTAssertFalse(harness.hasPendingSteps)
    }

    // MARK: Controller wiring

    /// Deterministic display: glide targets come from this rect.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1200),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1200),
        name: "Display 1")

    /// Captured animation steps and clock for tests driving the real
    /// controller: the step scheduler appends, `settle` fires generation
    /// by generation, advancing the clock one step per generation.
    /// Cancellers nil their slot, so a superseded glide leaves no fire.
    private final class ControllerGlide {
        private final class StepBox { var fire: (() -> Void)? }
        private var fires: [StepBox] = []
        var clock = Date()

        /// Whether a glide's next step (or landing) is still scheduled.
        var hasPending: Bool { fires.contains { $0.fire != nil } }

        var scheduleStep: Animator.StepScheduler {
            { [weak self] fire in
                let box = StepBox()
                box.fire = fire
                self?.fires.append(box)
                return { box.fire = nil }
            }
        }

        var now: () -> Date { { [weak self] in self?.clock ?? Date() } }

        func settle(maxGenerations: Int = 64) {
            var fired = 0
            while hasPending, fired < maxGenerations {
                clock = clock.addingTimeInterval(Animator.stepInterval)
                let generation = fires
                fires = []
                for box in generation { box.fire?() }
                fired += 1
            }
        }
    }

    func testControllerReadsTheAnimationProviderLive() {
        let gateway = FakeWindowGateway()
        let glide = ControllerGlide()
        var enabled = false
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            scheduleStep: glide.scheduleStep,
            animationEnabled: { enabled },
            reduceMotion: { false },
            screens: { [Self.screen] },
            deathConfirmation: 0,
            now: glide.now)
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        let grid = GridLayout()

        controller.handle(slot: .topLeft)
        let topLeft = grid.rect(for: .topLeft, in: Self.screen.visibleFrame)
        XCTAssertEqual(gateway.frame(of: handle), topLeft, "off writes instantly")

        enabled = true
        gateway.clearWrites()
        controller.handle(slot: .bottomRight)
        let bottomRight = grid.rect(for: .bottomRight, in: Self.screen.visibleFrame)
        XCTAssertNotEqual(gateway.frame(of: handle), bottomRight, "on glides from the first step")

        glide.settle()
        XCTAssertEqual(gateway.frame(of: handle), bottomRight, "the glide lands on its slot")
    }

    /// The app's real settings source, isolated per test: the controller
    /// reads it through the production provider closure (`{ settings
    /// .animateLayoutChanges }`), never a test-only stand-in.
    private func isolatedSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "AnimationTests-\(UUID().uuidString)")!)
    }

    func testSettingsToggleAppliesLiveToTheNextMove() {
        let settings = isolatedSettings()
        let gateway = FakeWindowGateway()
        let glide = ControllerGlide()
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            scheduleStep: glide.scheduleStep,
            animationEnabled: { settings.animateLayoutChanges },
            reduceMotion: { false },
            screens: { [Self.screen] },
            deathConfirmation: 0,
            now: glide.now)
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        let grid = GridLayout()
        let topLeft = grid.rect(for: .topLeft, in: Self.screen.visibleFrame)
        let bottomRight = grid.rect(for: .bottomRight, in: Self.screen.visibleFrame)

        // On by default: the first move glides.
        controller.handle(slot: .topLeft)
        XCTAssertNotEqual(
            gateway.frame(of: handle), topLeft,
            "the default-on setting glides from the first step")
        glide.settle()
        XCTAssertEqual(gateway.frame(of: handle), topLeft, "the glide lands on the slot")

        // Flipped off: the very next move snaps, no relaunch.
        settings.animateLayoutChanges = false
        gateway.clearWrites()
        controller.handle(slot: .bottomRight)
        XCTAssertEqual(gateway.frame(of: handle), bottomRight, "off snaps the next move")
        XCTAssertEqual(gateway.writes.count, 1, "one instant write")
        XCTAssertFalse(glide.hasPending, "no glide was started")

        // Flipped back on: glides again, still no relaunch.
        settings.animateLayoutChanges = true
        gateway.clearWrites()
        controller.handle(slot: .topLeft)
        XCTAssertNotEqual(gateway.frame(of: handle), topLeft, "on glides again")
        glide.settle()
        XCTAssertEqual(gateway.frame(of: handle), topLeft, "the second glide lands too")
    }

    func testReduceMotionOverridesTheSettingsToggleInBothPositions() {
        let settings = isolatedSettings()
        var reduceMotion = false
        let gateway = FakeWindowGateway()
        let glide = ControllerGlide()
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            scheduleStep: glide.scheduleStep,
            animationEnabled: { settings.animateLayoutChanges },
            reduceMotion: { reduceMotion },
            screens: { [Self.screen] },
            deathConfirmation: 0,
            now: glide.now)
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        let grid = GridLayout()
        let topLeft = grid.rect(for: .topLeft, in: Self.screen.visibleFrame)
        let bottomRight = grid.rect(for: .bottomRight, in: Self.screen.visibleFrame)

        // Control: with Reduce Motion off, the toggle's on position
        // glides, so a later snap can never be a dead animator.
        controller.handle(slot: .topLeft)
        XCTAssertNotEqual(
            gateway.frame(of: handle), topLeft,
            "toggle on glides when Reduce Motion is off")
        glide.settle()
        XCTAssertEqual(gateway.frame(of: handle), topLeft)

        // Toggle on + Reduce Motion on: snaps, Reduce Motion wins.
        reduceMotion = true
        gateway.clearWrites()
        controller.handle(slot: .bottomRight)
        XCTAssertEqual(
            gateway.frame(of: handle), bottomRight,
            "Reduce Motion overrides the on toggle")
        XCTAssertFalse(glide.hasPending, "no glide under Reduce Motion")

        // Toggle off + Reduce Motion on: still snaps.
        settings.animateLayoutChanges = false
        gateway.clearWrites()
        controller.handle(slot: .topLeft)
        XCTAssertEqual(
            gateway.frame(of: handle), topLeft,
            "toggle off and Reduce Motion both snap")
        XCTAssertFalse(glide.hasPending)

        // Reduce Motion is read live too: off again, the on toggle glides.
        settings.animateLayoutChanges = true
        reduceMotion = false
        gateway.clearWrites()
        controller.handle(slot: .bottomRight)
        XCTAssertNotEqual(
            gateway.frame(of: handle), bottomRight,
            "Reduce Motion turning off restores gliding")
        glide.settle()
        XCTAssertEqual(gateway.frame(of: handle), bottomRight)
    }

    func testControllerGlidesAnUntileBackToThePreTileFrame() {
        let gateway = FakeWindowGateway()
        let glide = ControllerGlide()
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            scheduleStep: glide.scheduleStep,
            animationEnabled: { true },
            reduceMotion: { false },
            screens: { [Self.screen] },
            deathConfirmation: 0,
            now: glide.now)
        let handle = gateway.addWindow(frame: CGRect(x: 100, y: 80, width: 500, height: 400))
        gateway.focused = handle
        let original = gateway.frame(of: handle)!

        controller.handle(slot: .topLeft)
        glide.settle()

        gateway.clearWrites()
        controller.untile(window: 1)

        XCTAssertEqual(gateway.writes.count, 1, "the restore's first step is synchronous")
        XCTAssertNotEqual(gateway.frame(of: handle), original, "the window is mid-glide")

        glide.settle()
        XCTAssertEqual(
            gateway.frame(of: handle), original,
            "the glide lands on the pre-tile frame")
    }

    // MARK: Correctness carve-outs

    func testDisplayChangeReassertsEveryOccupantInstantly() {
        let gateway = FakeWindowGateway()
        let glide = ControllerGlide()
        var screens = [Self.screen]
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            scheduleStep: glide.scheduleStep,
            animationEnabled: { true },
            reduceMotion: { false },
            screens: { screens },
            deathConfirmation: 0,
            now: glide.now)
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        glide.settle()
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 600, height: 500))
        gateway.focused = b
        controller.handle(slot: .topRight)
        glide.settle()
        gateway.clearWrites()

        // A display rearrange shrinks the visible frame: every occupant
        // must land on its new slot at once, never wait on a glide.
        let resized = ScreenInfo(
            id: Self.screen.id,
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            name: Self.screen.name)
        screens = [resized]
        let handled = XCTestExpectation(description: "display change handled")
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in handled.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        wait(for: [handled], timeout: 1.0)

        let grid = GridLayout()
        XCTAssertEqual(gateway.writes.count, 2, "one instant write per occupant")
        XCTAssertEqual(
            gateway.frame(of: a), grid.rect(for: .topLeft, in: resized.visibleFrame))
        XCTAssertEqual(
            gateway.frame(of: b), grid.rect(for: .topRight, in: resized.visibleFrame))
        XCTAssertFalse(glide.hasPending, "no glide steps are left after the reassert")
    }

    func testReassertWritesEveryOccupantInstantly() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.settleAnimations()
        harness.apply(slot: .bottomRight, requester: b)
        harness.settleAnimations()
        // Park both off their rects: the reassert must be a real write.
        let far = CGRect(x: -9_999, y: -9_999, width: 1, height: 1)
        harness.gateway.setFrame(harness.handle(of: a)!, to: far)
        harness.gateway.setFrame(harness.handle(of: b)!, to: far)
        harness.gateway.clearWrites()

        harness.space.reassert(context: harness.context(), animated: false)

        XCTAssertEqual(harness.gateway.writes.count, 2, "one instant write per occupant")
        XCTAssertEqual(harness.frame(of: a), harness.rect(.topLeft))
        XCTAssertEqual(harness.frame(of: b), harness.rect(.bottomRight))
        XCTAssertFalse(harness.hasPendingSteps, "no glide steps: the reassert is non-animated")
    }

    func testRefusedLandingRollsBackWithTheStandardRefusal() {
        let gateway = FakeWindowGateway()
        let glide = ControllerGlide()
        var feedbacks: [TilingController.Feedback] = []
        var changes = 0
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            scheduleStep: glide.scheduleStep,
            animationEnabled: { true },
            reduceMotion: { false },
            screens: { [Self.screen] },
            deathConfirmation: 0,
            now: glide.now)
        controller.onFeedback = { feedbacks.append($0) }
        controller.onChange = { changes += 1 }
        let handle = gateway.addWindow(frame: CGRect(x: 100, y: 80, width: 500, height: 400))
        gateway.focused = handle

        controller.handle(slot: .topLeft)
        // Fire the steps short of the landing, then refuse exactly it: the
        // glide tracked to within a pixel of the target, so only the
        // landing result can tell us the app refused the final write.
        glide.settle(maxGenerations: 10)
        let target = GridLayout().rect(for: .topLeft, in: Self.screen.visibleFrame)
        XCTAssertNotEqual(gateway.frame(of: handle), target, "the landing is still pending")
        gateway.refuseNextWrites(handle)
        let changesBefore = changes

        glide.settle()

        let canvas = controller.canvas(for: controller.focusedTilingSpace)
        XCTAssertNil(canvas.state.slot(of: 1), "occupancy rolled back on the refused landing")
        XCTAssertEqual(
            canvas.error, "TestApp couldn't be tiled: the app refused to resize it.")
        XCTAssertEqual(feedbacks.count, 1, "one refusal announcement")
        guard case .refused(let refusedName) = feedbacks.first else {
            return XCTFail("expected .refused, got \(feedbacks)")
        }
        XCTAssertEqual(refusedName, "TestApp")
        XCTAssertEqual(changes, changesBefore + 1, "the rollback announces the change")
        XCTAssertNotEqual(
            gateway.frame(of: handle), target,
            "the refused landing never reaches the target: the rollback is real")
        XCTAssertFalse(glide.hasPending)
    }

    func testRefusedLandingRollsBackTheCanvas() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        harness.apply(slot: .topLeft, requester: id)
        harness.settleAnimations(maxSteps: 10)
        XCTAssertTrue(harness.hasPendingSteps, "the landing is still scheduled")

        harness.gateway.refuseNextWrites(harness.handle(of: id)!)
        harness.settleAnimations()

        XCTAssertNil(harness.space.state.slot(of: id), "occupancy rolled back")
        XCTAssertNil(harness.space.records[id])
        XCTAssertEqual(
            harness.space.error,
            "TestApp couldn't be tiled: the app refused to resize it.",
            "the standard refusal wording lands on the canvas")
        XCTAssertNotEqual(
            harness.frame(of: id), harness.rect(.topLeft),
            "the refused landing never reaches the target")
        XCTAssertFalse(harness.hasPendingSteps)
    }

    func testSwapRollbackSnapsTheDisplacedWindowHome() {
        let a = harness.addWindow(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let b = harness.addWindow(frame: CGRect(x: 900, y: 100, width: 400, height: 300))
        harness.apply(slot: .topLeft, requester: a)
        harness.settleAnimations()
        harness.apply(slot: .topRight, requester: b)
        harness.settleAnimations()
        let aSlot = harness.rect(.topLeft)
        let bSlot = harness.rect(.topRight)
        harness.gateway.clearWrites()

        // a requests b's tile: the displaced window glides first, then
        // a's own write refuses, so the swap rolls back. The displaced
        // window must snap home instantly: a rollback write never glides.
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)
        let outcome = harness.apply(slot: .topRight, requester: a)

        guard case .refused = outcome.result else {
            return XCTFail("expected .refused, got \(outcome.result)")
        }
        XCTAssertEqual(harness.space.state.slot(of: a), .topLeft, "requester rolled back")
        XCTAssertEqual(harness.space.state.slot(of: b), .topRight, "displaced rolled back")
        XCTAssertEqual(
            harness.frame(of: b), bSlot,
            "the displaced window snaps home to the frame state claims")
        XCTAssertFalse(harness.hasPendingSteps, "the rollback supersedes the displaced glide")

        // Settling changes nothing: no stale step overwrites the rollback.
        harness.settleAnimations()
        XCTAssertEqual(harness.frame(of: b), bSlot)
        XCTAssertEqual(harness.frame(of: a), aSlot)
    }

    func testRefusedReflowSnapsTheHalfMovedSurvivorBack() {
        // Left and middle thirds plus the right third: evicting the
        // middle grows the right third into the right two-thirds (its
        // origin moves left), and that grow write half-applies (the app
        // took the origin, refused the size) and fails.
        let a = harness.addWindow(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let b = harness.addWindow(frame: CGRect(x: 700, y: 100, width: 400, height: 300))
        let c = harness.addWindow(frame: CGRect(x: 1200, y: 100, width: 300, height: 300))
        harness.apply(slot: .sixthLeft, requester: a)
        harness.settleAnimations()
        harness.apply(slot: .sixthMiddle, requester: b)
        harness.settleAnimations()
        harness.apply(slot: .sixthRight, requester: c)
        harness.settleAnimations()
        let cSlot = harness.rect(.sixthRight)
        harness.gateway.clearWrites()

        // c's grow write half-applies and fails: the reflow rolls state
        // back and must snap the survivor home, not glide after it.
        harness.gateway.refuseSizeWrites.insert(harness.handle(of: c)!)
        harness.space.release(window: b, context: harness.context())

        XCTAssertEqual(harness.space.state.slot(of: c), .sixthRight, "state rolled back")
        XCTAssertEqual(harness.frame(of: c), cSlot, "the half-moved survivor snaps back")
        XCTAssertFalse(harness.hasPendingSteps, "a rollback write never glides")
        XCTAssertEqual(
            harness.space.error, "Couldn't move that window: the app refused to resize it.")
    }

    // MARK: Re-house failure cleanup

    /// The sixths setup the re-house fallbacks use: bottom-left sixth (b),
    /// middle third (m), right third (r), each with its own pre-tile frame.
    private func tileSixthsColumn() -> (b: WindowID, m: WindowID, r: WindowID) {
        let b = harness.addWindow(frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        harness.apply(slot: .sixthBottomLeft, requester: b)
        harness.settleAnimations()
        let m = harness.addWindow(frame: CGRect(x: 600, y: 150, width: 350, height: 250))
        harness.apply(slot: .sixthMiddle, requester: m)
        harness.settleAnimations()
        let r = harness.addWindow(frame: CGRect(x: 1100, y: 200, width: 400, height: 300))
        harness.apply(slot: .sixthRight, requester: r)
        harness.settleAnimations()
        return (b, m, r)
    }

    func testRefusedRehouseRestoresTheVictimInstantly() {
        let (_, m, r) = tileSixthsColumn()
        let rOriginal = CGRect(x: 1100, y: 200, width: 400, height: 300)
        harness.gateway.refuseNextWrites(harness.handle(of: r)!)
        harness.gateway.clearWrites()

        harness.apply(slot: .sixthsRightTwoThirds, requester: m)

        XCTAssertNil(harness.space.state.slot(of: r), "the refused re-house falls back to eviction")
        XCTAssertEqual(
            harness.frame(of: r), rOriginal,
            "failure cleanup snaps the victim home, not a glide")
    }

    func testRefusedRequesterRestoresTheRehouseVictimInstantly() {
        let (_, m, r) = tileSixthsColumn()
        let rOriginal = CGRect(x: 1100, y: 200, width: 400, height: 300)
        harness.gateway.refuseNextWrites(harness.handle(of: m)!)
        harness.gateway.clearWrites()

        harness.apply(slot: .sixthsRightTwoThirds, requester: m)

        XCTAssertNil(harness.space.state.slot(of: m), "the requester's refusal rolled back")
        XCTAssertNil(harness.space.state.slot(of: r), "the victim untiles")
        XCTAssertEqual(
            harness.frame(of: r), rOriginal,
            "failure cleanup snaps the victim home, not a glide")
    }

    func testSilentIgnoredGlideRollsBackAtVerification() {
        let gateway = FakeWindowGateway()
        let glide = ControllerGlide()
        var verifyFires: [() -> Void] = []
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { fire in
                verifyFires.append(fire)
                return {}
            },
            scheduleStep: glide.scheduleStep,
            animationEnabled: { true },
            reduceMotion: { false },
            screens: { [Self.screen] },
            deathConfirmation: 0,
            now: glide.now)
        let handle = gateway.addWindow(frame: CGRect(x: 100, y: 80, width: 500, height: 400))
        gateway.focused = handle
        gateway.silentIgnore.insert(handle)

        // The app accepts every write and applies none: the glide lands
        // "successfully" on a frame the window never reached. The late
        // convergence check is still the judge for an accepted off-target
        // landing, exactly as it is for an instant write.
        controller.handle(slot: .topLeft)
        glide.settle()
        XCTAssertEqual(
            controller.canvas(for: controller.focusedTilingSpace).state.slot(of: 1),
            .topLeft, "the write was accepted")

        verifyFires.last?()

        let canvas = controller.canvas(for: controller.focusedTilingSpace)
        XCTAssertNil(canvas.state.slot(of: 1), "the silent ignore rolls back")
        XCTAssertNotNil(canvas.error)
        XCTAssertNotEqual(
            gateway.frame(of: handle),
            GridLayout().rect(for: .topLeft, in: Self.screen.visibleFrame),
            "the window never reached its slot")
    }

    func testLandingOnAHiddenCanvasDefersInsteadOfFailing() {
        let id = harness.addWindow(frame: CGRect(x: 200, y: 200, width: 400, height: 300))
        harness.apply(slot: .topLeft, requester: id)
        harness.settleAnimations(maxSteps: 10)
        XCTAssertTrue(harness.hasPendingSteps, "the landing is still scheduled")

        // The canvas goes hidden mid-glide: the landing defers (the
        // off-Space policy) and the tile stands, waiting for the swipe
        // back. A deferral is not a refusal and must not roll the
        // placement back.
        harness.canvasVisible = false
        harness.settleAnimations()

        XCTAssertEqual(harness.space.state.slot(of: id), .topLeft, "the tile stands")
        XCTAssertNil(harness.space.error, "a deferral is not a failure")
        XCTAssertFalse(harness.hasPendingSteps)
    }

    func testDisplayChangeMidGlideSupersedesTheGlideInstantly() {
        let gateway = FakeWindowGateway()
        let glide = ControllerGlide()
        var screens = [Self.screen]
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            scheduleStep: glide.scheduleStep,
            animationEnabled: { true },
            reduceMotion: { false },
            screens: { screens },
            deathConfirmation: 0,
            now: glide.now)
        let handle = gateway.addWindow(frame: CGRect(x: 100, y: 80, width: 500, height: 400))
        gateway.focused = handle

        controller.handle(slot: .topLeft)
        glide.settle(maxGenerations: 3)
        XCTAssertTrue(glide.hasPending, "the tile glide is still in flight")
        gateway.clearWrites()

        let resized = ScreenInfo(
            id: Self.screen.id,
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            name: Self.screen.name)
        screens = [resized]
        let handled = XCTestExpectation(description: "display change handled")
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in handled.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        wait(for: [handled], timeout: 1.0)

        let reasserted = GridLayout().rect(for: .topLeft, in: resized.visibleFrame)
        XCTAssertEqual(gateway.frame(of: handle), reasserted, "the reassert lands at once")
        XCTAssertFalse(glide.hasPending, "the in-flight glide is superseded")

        // The abandoned glide must never land its old-screen target.
        glide.settle()
        XCTAssertEqual(
            gateway.frame(of: handle), reasserted,
            "no stale step overwrites the display reassert")
    }
}
