import CoreGraphics
import XCTest
@testable import tiled

/// The rollback outcomes every expected-write path owes before the
/// `MoveAttempt` transaction lands: a refused write either moved nothing
/// (state-only rollback) or moved the window (state restore plus the
/// reverse write home). These pins are deliberately written through the
/// canvas's own interface, so the transaction can replace the bodies
/// underneath without changing the observable contract.
final class ExpectedWriteTransactionTests: XCTestCase {
    private var harness: TilingSpaceHarness!

    override func setUp() {
        super.setUp()
        harness = TilingSpaceHarness()
    }

    private var space: TilingSpace { harness.space }

    private func tile(_ id: WindowID, _ slot: Slot) {
        harness.apply(slot: slot, requester: id)
    }

    func testRefusedFirstPlacementReleasesTheRecordAndLeavesTheWindowWhereItWas() {
        let id = harness.addWindow(frame: CGRect(x: 40, y: 50, width: 500, height: 400))
        let original = harness.frame(of: id)!
        harness.gateway.refuseNextWrites(harness.handle(of: id)!)

        let outcome = harness.apply(slot: .topLeft, requester: id)

        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
        XCTAssertNil(space.state.slot(of: id), "a refused first tiling leaves no occupancy")
        XCTAssertNil(space.records[id], "the record goes with the occupancy")
        XCTAssertEqual(harness.frame(of: id), original, "the refused write moved nothing")
        XCTAssertEqual(
            space.error, "TestApp couldn't be tiled: the app refused to resize it.")
    }

    func testRefusedMoveOfTiledWindowRollsBackTheSlotWithoutAReverseWrite() {
        // A refused move never puts the target on screen, so the rollback
        // restores state only: writing the old slot back would be a second
        // unnecessary write against a window that never left it.
        let id = harness.addWindow()
        tile(id, .topLeft)
        harness.gateway.clearWrites()
        harness.gateway.refuseNextWrites(harness.handle(of: id)!)

        let outcome = harness.apply(slot: .bottomRight, requester: id)

        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
        XCTAssertEqual(space.state.slot(of: id), .topLeft)
        XCTAssertEqual(space.records[id]?.handle, harness.handle(of: id))
        XCTAssertTrue(harness.gateway.writes.isEmpty, "the refusal issued no frame write")
    }

    func testRefusedDisplacedSwapWriteRollsBackWithoutWritingTheRequester() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        tile(a, .topLeft)
        tile(b, .topRight)
        harness.gateway.clearWrites()
        harness.gateway.refuseNextWrites(harness.handle(of: b)!)

        let outcome = harness.apply(slot: .topRight, requester: a)

        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
        XCTAssertEqual(space.state.slot(of: a), .topLeft, "the requester never moved")
        XCTAssertEqual(space.state.slot(of: b), .topRight)
        XCTAssertTrue(
            harness.gateway.writes.isEmpty,
            "the displaced refusal stopped the swap before the requester was written")
    }

    func testRefusedRequesterSwapWriteWritesTheDisplacedWindowHome() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        tile(a, .topLeft)
        tile(b, .topRight)
        harness.gateway.clearWrites()
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)

        let outcome = harness.apply(slot: .topRight, requester: a)

        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
        XCTAssertEqual(space.state.slot(of: a), .topLeft)
        XCTAssertEqual(space.state.slot(of: b), .topRight)
        XCTAssertEqual(
            harness.gateway.writes.map(\.handle),
            [harness.handle(of: b)!, harness.handle(of: b)!],
            "the displaced window moves into the vacated tile, then back home")
        XCTAssertEqual(
            harness.gateway.writes.map(\.frame),
            [harness.rect(.topLeft), harness.rect(.topRight)])
        XCTAssertEqual(
            space.error, "TestApp couldn't be tiled: the app refused to resize it.")
    }

    func testRefusedRequesterAndHomeWritesKeepTheDisplacedWindowInTheVacatedTile() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        tile(a, .topLeft)
        tile(b, .topRight)
        let bHandle = harness.handle(of: b)!
        harness.gateway.clearWrites()
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)
        var bWrites = 0
        harness.gateway.willWrite = { handle in
            guard handle == bHandle else { return }
            bWrites += 1
            if bWrites == 2 {
                self.harness.gateway.refuseNextWrites(bHandle)
            }
        }

        harness.apply(slot: .topRight, requester: a)

        XCTAssertEqual(space.state.slot(of: a), .topLeft)
        XCTAssertEqual(space.state.slot(of: b), .topRight)
        XCTAssertEqual(
            harness.frame(of: b), harness.rect(.topLeft),
            "the failed home write leaves the window visibly in the vacated tile")
        XCTAssertEqual(
            space.error,
            "TestApp couldn't be tiled: the app refused to resize it. "
                + "Couldn't restore \u{201C}TestApp\u{201D}: it may still be sitting in its old tile.")
    }

    func testRefusedUndoRetileKeepsTheSlotAndRecordTheWindowVisiblyHolds() {
        // The chapter asks the window to return to Bottom Right, but it is
        // tiled at Top Left and its app refuses the re-tile. The rollback
        // must restore both the visible slot and the record captured before
        // the chapter overwrote its pre-tile frame.
        let a = harness.addWindow(frame: CGRect(x: 40, y: 50, width: 500, height: 400))
        tile(a, .topLeft)
        let originalRecord = space.records[a]!
        let entry = EvictedWindow(
            handle: harness.handle(of: a)!, slot: .bottomRight,
            preTileFrame: CGRect(x: 1, y: 2, width: 3, height: 4),
            space: .displayless)
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)

        let result = harness.restoreEvictees([entry])

        XCTAssertEqual(result.failures.map(\.name), ["TestApp"])
        XCTAssertTrue(result.restored.isEmpty)
        XCTAssertTrue(result.forget.isEmpty, "the window never left this canvas")
        XCTAssertEqual(space.state.slot(of: a), .topLeft)
        XCTAssertEqual(
            space.records[a]?.preTileFrame, originalRecord.preTileFrame,
            "the rollback restores the record captured before the chapter")
        XCTAssertEqual(harness.frame(of: a), harness.rect(.topLeft))
    }
}
