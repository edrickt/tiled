import XCTest
@testable import tiled

/// Closes the "commit dance" gap without copying it: every (occupancy,
/// request) pair from the pure plan matrices is replayed through the
/// canvas (`TilingSpace` with a fake gateway and injected bounds) and
/// checked against the model's plan-defined contract. The model is
/// `plan` itself plus the pure rules (`rehousingHome`, `reflow`); the
/// test never re-implements the placement pipeline's commit order.
/// Both requester kinds run: a fresh untiled window (tile/evict/switch
/// paths) and an already-tiled window (move and no-op paths, which only
/// tiled requesters can produce).
final class MatrixCrossCheckTests: XCTestCase {
    func testCanvasMatchesThePlanContractForFreshRequesters() {
        runMatrix(requester: .fresh)
    }

    func testCanvasMatchesThePlanContractForTiledRequesters() {
        runMatrix(requester: .tiled)
    }

    // MARK: Canvas vs. model

    /// The contract of one plan, asserted on the canvas that executed it:
    /// - `.noop`: nothing changed.
    /// - `.swap`: the two windows trade tiles, nobody else moves.
    /// - `.tile`: the requester lands, every evictee either re-houses
    ///   into the one whole slot the request freed (`rehousingHome`) or
    ///   is gone, and every survivor stays tiled.
    /// Structural health (one layout, no ghosts, no double-booked cells)
    /// is checked after every case.
    private func assertCanvasFollows(
        _ plan: TilePlan, harness: TilingSpaceHarness, model: TilingState,
        requester: WindowID, target: Slot, context: String
    ) {
        let canvas = harness.space
        switch plan {
        case .noop:
            XCTAssertEqual(canvas.state, model, "\(context): noop changed the state")
        case .swap(let displaced):
            guard let previous = model.slot(of: requester),
                let displacedSlot = model.slot(of: displaced)
            else {
                return XCTFail("\(context): swap plan without both tiles")
            }
            var expected = model.occupants
            expected[previous] = nil
            expected[displacedSlot] = nil
            expected[target] = requester
            expected[previous] = displaced
            XCTAssertEqual(
                canvas.state.occupants, expected,
                "\(context): the displaced window takes the vacated tile")
        case .tile(let evicting):
            XCTAssertEqual(
                canvas.state.occupant(of: target), requester,
                "\(context): the requester lands in its slot")
            for evicted in evicting {
                if evicted == requester { continue }
                // Only a lone evictee is ever re-housed (the canvas's
                // rule); with more than one, everyone goes home.
                if evicting.count == 1,
                    let home = model.rehousingHome(
                        evicting: evicted, for: target, vacating: model.slot(of: requester))
                {
                    XCTAssertEqual(
                        canvas.state.slot(of: evicted), home,
                        "\(context): the lone evictee re-houses into the one free slot")
                } else {
                    XCTAssertNil(
                        canvas.state.slot(of: evicted),
                        "\(context): a window with no re-house slot is released")
                }
            }
            // Survivors: reflow may grow them, never drop them.
            let survivors = Set(model.tiledWindows).subtracting(evicting)
            for survivor in survivors {
                XCTAssertNotNil(
                    canvas.state.slot(of: survivor),
                    "\(context): a survivor must keep a tile")
            }
        }
        assertHealthy(canvas.state.occupants, context: context)
    }

    private func assertHealthy(_ occupants: [Slot: WindowID], context: String) {
        var seen: Set<TileCell> = []
        for slot in occupants.keys {
            for cell in slot.cells {
                XCTAssertFalse(seen.contains(cell), "\(context): cell \(cell) double-booked")
                seen.insert(cell)
            }
        }
        XCTAssertLessThanOrEqual(
            Set(occupants.keys.map(\.layout)).count, 1, "\(context): mixed layouts on screen")
        XCTAssertEqual(
            Set(occupants.values).count, occupants.count,
            "\(context): a window appears in two slots")
    }

    // MARK: Engine

    private enum RequesterKind {
        case fresh
        case tiled
    }

    private static var quartersConfigs: [[Slot]] {
        [
            [.topLeft],
            [.bottomRight],
            [.leftHalf],
            [.rightHalf],
            [.topLeft, .bottomRight],
            [.leftHalf, .topRight],
            [.leftHalf, .rightHalf],
            [.topLeft, .bottomLeft],
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.leftHalf, .topRight, .bottomRight],
            [.rightHalf, .topLeft, .bottomLeft],
        ]
    }

    private static var sixthsConfigs: [[Slot]] {
        [
            [.sixthTopLeft],
            [.sixthTopMiddle],
            [.sixthMiddle],
            [.sixthsLeftTwoThirds],
            [.sixthLeft, .sixthRight],
            [.sixthTopLeft, .sixthBottomRight],
            [.sixthLeft, .sixthMiddle, .sixthRight],
            [.sixthsLeftTwoThirds, .sixthRight],
            [.sixthsRightTwoThirds, .sixthLeft],
            [.sixthTopLeft, .sixthTopMiddle, .sixthTopRight],
            [
                .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
                .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
            ],
            [.sixthLeft, .sixthTopMiddle, .sixthTopRight,
             .sixthBottomMiddle, .sixthBottomRight],
        ]
    }

    private func runMatrix(requester kind: RequesterKind) {
        let matrices: [(layout: LayoutKind, configs: [[Slot]])] = [
            (.quarters, Self.quartersConfigs),
            (.sixths, Self.sixthsConfigs),
        ]
        for (layout, configs) in matrices {
            for config in configs {
                for target in Slot.allCases where target.layout == layout {
                    let harness = TilingSpaceHarness()
                    // The canvas's layout is a stored choice; the matrix
                    // only asks for slots inside it.
                    harness.space.adoptLayout(layout)
                    // Tile the occupancy shape: ids 1...count, in order.
                    // Configs are pairwise disjoint, so every setup tile
                    // is a plain placement.
                    for slot in config {
                        let id = harness.addWindow()
                        harness.apply(slot: slot, requester: id)
                    }

                    let requesterID: WindowID
                    switch kind {
                    case .fresh:
                        requesterID = harness.addWindow()
                    case .tiled:
                        requesterID = 1
                    }

                    // The model over the same occupancy.
                    var model = TilingState(layout: layout)
                    for (index, slot) in config.enumerated() {
                        model.commit(window: index + 1, into: slot)
                    }
                    let plan = model.plan(window: requesterID, into: target)

                    let context =
                        "\(kind) \(layout.rawValue) \(config) -> \(target.rawValue) [\(plan)]"
                    XCTAssertEqual(
                        harness.space.state.occupants, model.occupants,
                        "\(context): canvas and model start from the same occupancy")

                    harness.apply(slot: target, requester: requesterID)

                    assertCanvasFollows(
                        plan, harness: harness, model: model,
                        requester: requesterID, target: target, context: context)
                }
            }
        }
    }

    // MARK: Canvas replay of short sequences

    /// Every request sequence up to two hops over three windows: replay
    /// it through a fresh canvas, assert the structural invariants after
    /// EVERY step, and extend only sequences that reach a new occupancy.
    /// The plans come from the canvas's own pure state; the canvas
    /// executes them. Every sequence stays inside the canvas's sixths
    /// layout; the switch path is covered by the controller suites.
    func testShortRequestSequencesKeepTheCanvasInvariants() {
        var queue: [[(WindowID, Slot)]] = [[]]
        var visited: Set<String> = []
        var steps = 0
        let sixthsSlots = Slot.allCases.filter { $0.layout == .sixths }
        while !queue.isEmpty {
            let path = queue.removeFirst()
            let harness = TilingSpaceHarness()
            let ids = (0..<3).map { _ in harness.addWindow() }
            for (window, slot) in path {
                harness.apply(slot: slot, requester: window)
                steps += 1
                assertHealthy(
                    harness.space.state.occupants,
                    context: "path \(path) after win\(window) -> \(slot.rawValue)")
            }
            guard path.count < 2 else { continue }
            let key = occupancyKey(harness.space.state.occupants)
            guard visited.insert(key).inserted else { continue }
            for window in ids {
                for slot in sixthsSlots {
                    queue.append(path + [(window, slot)])
                }
            }
        }
        XCTAssertGreaterThan(steps, 1000, "BFS explored too little")
    }

    private func occupancyKey(_ occupants: [Slot: WindowID]) -> String {
        occupants
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted().joined(separator: ",")
    }
}
