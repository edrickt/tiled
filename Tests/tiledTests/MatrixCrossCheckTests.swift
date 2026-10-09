import XCTest
@testable import tiled

/// Closes the "commit dance" gap without copying it: every (occupancy,
/// request) pair from the pure plan matrices is replayed through the
/// canvas (`TilingSpace` with a fake gateway and injected bounds) and
/// checked against an independent oracle. `MatrixOracle` states the
/// expected outcome per matrix case in its own terms — the plan rules
/// written from `CONTEXT.md` over Slots and Cells, never a call into
/// the code under test — so a wrong re-housing home is caught, not
/// agreed with. The model (`plan`) runs alongside: where the canvas and
/// the model diverge, the cross-check names the divergence; where the
/// model and the oracle disagree, it names the drifted rule. Both
/// requester kinds run: a fresh untiled window (tile/evict/switch
/// paths) and an already-tiled window (move and no-op paths, which only
/// tiled requesters can produce).
final class MatrixCrossCheckTests: XCTestCase {
    func testCanvasMatchesThePlanContractForFreshRequesters() {
        runMatrix(requester: .fresh)
    }

    func testCanvasMatchesThePlanContractForTiledRequesters() {
        runMatrix(requester: .tiled)
    }

    // MARK: Canvas vs. oracle vs. model

    /// The contract of one plan, asserted on the canvas that executed
    /// it, in three layers:
    /// - the model's plan must match the oracle's reading of the rules
    ///   (`CONTEXT.md`), or a rule has drifted from its spec;
    /// - the canvas must have executed the model's plan (divergence
    ///   detection between canvas and model);
    /// - the canvas must land where the oracle says — explicit expected
    ///   homes per evictee and a stated slot per survivor — because rule
    ///   correctness cannot rest on the rule under test.
    /// Structural health (one layout, no ghosts, no double-booked cells)
    /// is checked after every case.
    private func assertCanvasFollows(
        _ oracle: MatrixOracle.Expectation, plan: TilePlan, replay: Replay,
        target: Slot, context: String
    ) {
        let canvas = replay.harness.space
        XCTAssertEqual(
            shape(of: plan), oracle.plan,
            "\(context): the model's plan disagrees with the oracle's rules")
        switch plan {
        case .noop:
            XCTAssertEqual(canvas.state, replay.model, "\(context): noop changed the state")
        case .switchLayout:
            XCTAssertEqual(
                canvas.state.occupants, [target: replay.requester],
                "\(context): a switch leaves exactly the requester")
        case .swap(let displaced):
            guard let previous = replay.model.slot(of: replay.requester),
                let displacedSlot = replay.model.slot(of: displaced)
            else {
                return XCTFail("\(context): swap plan without both tiles")
            }
            var expected = replay.model.occupants
            expected[previous] = nil
            expected[displacedSlot] = nil
            expected[target] = replay.requester
            expected[previous] = displaced
            XCTAssertEqual(
                canvas.state.occupants, expected,
                "\(context): the displaced window takes the vacated tile")
        case .tile(let evicting):
            XCTAssertEqual(
                canvas.state.occupant(of: target), replay.requester,
                "\(context): the requester lands in its slot")
            // The re-housing expectation per victim: an explicit
            // expected home from the oracle. A home computed by
            // `rehousingHome` here would be the rule judging itself —
            // a wrong home would be agreed with, not caught.
            for evictee in evicting where evictee != replay.requester {
                if let home = oracle.homes[evictee] {
                    XCTAssertEqual(
                        canvas.state.slot(of: evictee), home,
                        "\(context): win\(evictee) re-houses into \(home.rawValue)")
                    XCTAssertEqual(
                        replay.harness.frame(of: evictee), replay.harness.rect(home),
                        "\(context): win\(evictee)'s frame is its home's rect")
                } else {
                    XCTAssertNil(
                        canvas.state.slot(of: evictee),
                        "\(context): a window with no whole-slot home is untiled")
                }
            }
            // Survivors: which slot each one holds — its cells and its
            // written rect — not mere presence. Reflow may grow a
            // survivor; the oracle states into what.
            let survivors = Set(replay.model.tiledWindows)
                .subtracting(evicting)
                .subtracting([replay.requester])
            for survivor in survivors {
                let expectedSlot = oracle.occupants.first { $0.value == survivor }?.key
                XCTAssertEqual(
                    canvas.state.slot(of: survivor), expectedSlot,
                    "\(context): survivor win\(survivor) holds the slot the rules give it")
                if let expectedSlot {
                    XCTAssertEqual(
                        canvas.state.slot(of: survivor)?.cells, expectedSlot.cells,
                        "\(context): survivor win\(survivor) holds exactly these cells")
                    XCTAssertEqual(
                        replay.harness.frame(of: survivor), replay.harness.rect(expectedSlot),
                        "\(context): survivor win\(survivor)'s frame is its slot's rect")
                }
            }
        }
        // The oracle states the whole expected outcome per matrix case.
        XCTAssertEqual(
            canvas.state.occupants, oracle.occupants,
            "\(context): the final occupancy diverges from the oracle")
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

    /// The model's decision read into the oracle's vocabulary, for the
    /// rule-agreement check only.
    private func shape(of plan: TilePlan) -> MatrixOracle.Plan {
        switch plan {
        case .noop: .noop
        case .switchLayout: .switchLayout
        case .swap(let displaced): .swap(displaced: displaced)
        case .tile(let evicting): .tile(evicting: evicting)
        }
    }

    // MARK: Engine

    private enum RequesterKind {
        case fresh
        case tiled
    }

    /// One replay's parts: the canvas run over the config's occupancy,
    /// the model over the same occupancy, and the requester's id.
    private struct Replay {
        var harness: TilingSpaceHarness
        var model: TilingState
        var requester: WindowID
    }

    /// Builds one replay without requesting anything: the config tiles
    /// in order (ids 1...count — configs are pairwise disjoint, so every
    /// setup tile is a plain placement), and the requester is either a
    /// fresh untiled window (`nil`) or the config's window with that id.
    private func replay(config: [Slot], requester: WindowID?) -> Replay {
        let harness = TilingSpaceHarness()
        for slot in config {
            let id = harness.addWindow()
            harness.apply(slot: slot, requester: id)
        }
        var model = TilingState()
        for (index, slot) in config.enumerated() {
            model.commit(window: index + 1, into: slot)
        }
        return Replay(
            harness: harness, model: model, requester: requester ?? harness.addWindow())
    }

    private func runMatrix(requester kind: RequesterKind) {
        let matrices: [(layout: LayoutKind, configs: [[Slot]])] = [
            (.quarters, LayoutSwitchTests.quartersConfigs),
            (.sixths, LayoutSwitchTests.sixthsConfigs),
        ]
        for (layout, configs) in matrices {
            for config in configs {
                for target in Slot.allCases {
                    let replay = replay(config: config, requester: kind == .fresh ? nil : 1)
                    let plan = replay.model.plan(window: replay.requester, into: target)
                    // The oracle states the expected outcome before the
                    // canvas runs: the canvas is compared against a
                    // prediction, not against its own echo.
                    let oracle = MatrixOracle.expectation(
                        occupants: replay.model.occupants,
                        requester: replay.requester, target: target)
                    let context =
                        "\(kind) \(layout.rawValue) \(config) -> \(target.rawValue) [\(plan)]"
                    XCTAssertEqual(
                        replay.harness.space.state.occupants, replay.model.occupants,
                        "\(context): canvas and model start from the same occupancy")
                    replay.harness.apply(slot: target, requester: replay.requester)
                    assertCanvasFollows(
                        oracle, plan: plan, replay: replay, target: target, context: context)
                }
            }
        }
    }

    // MARK: Explicit expected homes

    /// The re-housing scenarios `CONTEXT.md` names, written down by hand
    /// in the rule's own terms: an occupancy shape, a request, and the
    /// exact homes and final occupancy that must result. These literals
    /// — not any computation — are the trust anchor the oracle is held
    /// to; the matrix then sweeps every other case against the anchored
    /// oracle. Each pin is replayed through the canvas too, so a
    /// written-down home is checked against the screen, not just the
    /// model of it.
    func testExplicitExpectedHomesPinTheReHousingRule() {
        struct Pin {
            /// The occupancy shape, tiled by consecutive ids (1...).
            let config: [Slot]
            /// The requester: a fresh untiled window (`nil`) or the
            /// config's window with this id.
            let requester: WindowID?
            let target: Slot
            /// Every re-housed victim's expected home, explicitly.
            let homes: [WindowID: Slot]
            /// The whole expected outcome.
            let expected: [Slot: WindowID]
            /// The rule text this pin was written from.
            let rule: String
        }
        let pins: [Pin] = [
            Pin(
                config: [.sixthLeft], requester: nil, target: .sixthTopLeft,
                homes: [1: .sixthBottomLeft],
                expected: [.sixthTopLeft: 2, .sixthBottomLeft: 1],
                rule: "the left third requested at its top sixth steps down into the bottom-left sixth"),
            Pin(
                config: [.leftHalf], requester: nil, target: .topLeft,
                homes: [1: .bottomLeft],
                expected: [.topLeft: 2, .bottomLeft: 1],
                rule: "the left half into the bottom-left quad"),
            Pin(
                config: [.sixthsLeftTwoThirds], requester: nil, target: .sixthLeft,
                homes: [1: .sixthMiddle],
                expected: [.sixthLeft: 2, .sixthMiddle: 1],
                rule: "a two-thirds into the third its request leaves clean"),
            Pin(
                config: [.sixthsLeftTwoThirds], requester: nil, target: .sixthsRightTwoThirds,
                homes: [1: .sixthLeft],
                expected: [.sixthsRightTwoThirds: 2, .sixthLeft: 1],
                rule: "the one overlap that is not a containment — a left two-thirds blocking a right two-thirds request — steps aside into the left third"),
            Pin(
                config: [.sixthsRightTwoThirds], requester: nil, target: .sixthsLeftTwoThirds,
                homes: [1: .sixthRight],
                expected: [.sixthsLeftTwoThirds: 2, .sixthRight: 1],
                rule: "the same crossing in the other direction steps into the right third"),
            Pin(
                config: [.sixthBottomLeft, .sixthMiddle], requester: nil,
                target: .sixthsRightTwoThirds,
                homes: [2: .sixthTopLeft],
                expected: [
                    .sixthsRightTwoThirds: 3, .sixthTopLeft: 2, .sixthBottomLeft: 1,
                ],
                rule: "with the bottom-left sixth occupied, the middle third making room for the right two-thirds moves into the free top-left sixth"),
            Pin(
                config: [.sixthsLeftTwoThirds, .sixthRight], requester: 1,
                target: .sixthsRightTwoThirds,
                homes: [2: .sixthLeft],
                expected: [.sixthsRightTwoThirds: 1, .sixthLeft: 2],
                rule: "the cells left free after the request include the requester's vacated tile"),
            Pin(
                config: [.sixthsLeftTwoThirds], requester: nil, target: .sixthTopLeft,
                homes: [:],
                expected: [.sixthTopLeft: 2],
                rule: "a leftover that is not exactly one slot falls back to untile-and-restore"),
            Pin(
                config: [.topLeft, .bottomRight], requester: nil, target: .bottomRight,
                homes: [:],
                expected: [.topLeft: 1, .bottomRight: 3],
                rule: "a free region that is not exactly one slot falls back to untile-and-restore"),
            Pin(
                config: [.sixthBottomLeft, .sixthMiddle, .sixthRight], requester: nil,
                target: .sixthsRightTwoThirds,
                homes: [:],
                expected: [.sixthsRightTwoThirds: 4, .sixthBottomLeft: 1],
                rule: "only a lone evictee re-houses; with more than one, everyone goes home"),
            Pin(
                config: [.leftHalf, .rightHalf], requester: 1, target: .topRight,
                homes: [2: .bottomRight],
                expected: [.topRight: 1, .bottomRight: 2],
                rule: "the step-aside covers tiled requesters too: it wins over a swap"),
            Pin(
                config: [.topLeft, .bottomLeft], requester: 1, target: .topRight,
                homes: [:],
                expected: [.topRight: 1, .leftHalf: 2],
                rule: "the requester's vacated cells merge with exactly one adjacent survivor into a whole slot"),
            Pin(
                config: [.sixthTopLeft, .sixthBottomLeft], requester: 2, target: .sixthTopRight,
                homes: [:],
                expected: [.sixthLeft: 1, .sixthTopRight: 2],
                rule: "the top-left sixth whose bottom mate left becomes the left third"),
        ]
        for pin in pins {
            let replay = replay(config: pin.config, requester: pin.requester)
            let oracle = MatrixOracle.expectation(
                occupants: replay.model.occupants,
                requester: replay.requester, target: pin.target)
            let context = "[\(pin.rule)] \(pin.config) -> \(pin.target.rawValue)"
            // The oracle must state the written-down outcome ...
            XCTAssertEqual(
                oracle.homes, pin.homes,
                "\(context): the oracle's homes disagree with the written-down homes")
            XCTAssertEqual(
                oracle.occupants, pin.expected,
                "\(context): the oracle's outcome disagrees with the written-down outcome")
            // ... and the canvas must land there.
            replay.harness.apply(slot: pin.target, requester: replay.requester)
            XCTAssertEqual(
                replay.harness.space.state.occupants, pin.expected,
                "\(context): the canvas disagrees with the written-down outcome")
        }
    }

    // MARK: Canvas replay of short sequences

    /// Every request sequence up to two hops over three windows: replay
    /// it through a fresh canvas, assert the structural invariants after
    /// EVERY step, and extend only sequences that reach a new occupancy.
    /// The plans come from the canvas's own pure state; the canvas
    /// executes them. Switches must occur in both directions, or the
    /// sweep proved nothing.
    func testShortRequestSequencesKeepTheCanvasInvariants() {
        var queue: [[(WindowID, Slot)]] = [[]]
        var visited: Set<String> = []
        var steps = 0
        var quartersToSixths = 0
        var sixthsToQuarters = 0
        while !queue.isEmpty {
            let path = queue.removeFirst()
            let harness = TilingSpaceHarness()
            let ids = (0..<3).map { _ in harness.addWindow() }
            for (window, slot) in path {
                let plan = harness.space.state.plan(window: window, into: slot)
                if case .switchLayout = plan {
                    if slot.layout == .sixths {
                        quartersToSixths += 1
                    } else {
                        sixthsToQuarters += 1
                    }
                }
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
                for slot in Slot.allCases {
                    queue.append(path + [(window, slot)])
                }
            }
        }
        XCTAssertGreaterThan(steps, 1000, "BFS explored too little")
        XCTAssertGreaterThan(quartersToSixths, 0, "BFS never switched quarters -> sixths")
        XCTAssertGreaterThan(sixthsToQuarters, 0, "BFS never switched sixths -> quarters")
    }

    private func occupancyKey(_ occupants: [Slot: WindowID]) -> String {
        occupants
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted().joined(separator: ",")
    }
}
