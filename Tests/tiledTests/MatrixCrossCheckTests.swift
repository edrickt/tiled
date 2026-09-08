import XCTest
@testable import tiled

/// Closes the "commit dance" gap: the pure-state matrices in
/// LayoutSwitchTests validate `plan()` against a hand-written copy of
/// the controller's apply order. Here every (occupancy, request) pair
/// from those same matrices is replayed through the real
/// `TilingController.handle` (restore ordering, record lifecycle, commit,
/// and cross-layout reset included) and the end state must match the pure
/// plan application exactly. Both requester kinds run: a fresh untiled
/// window (tile/evict/switch paths) and an already-tiled window (move
/// and no-op paths, which only tiled requesters can produce).
final class MatrixCrossCheckTests: XCTestCase {
    /// The pure contract: evicted windows are removed before the requester
    /// is committed. Cross-validated against the real controller by this
    /// very test.
    private func applyExpected(
        _ plan: TilePlan, requester: WindowID, target: Slot, to state: inout TilingState
    ) {
        switch plan {
        case .noop:
            break
        case .swap(let displaced):
            if let previous = state.slot(of: requester) {
                state.commit(window: displaced, into: previous)
            }
            state.commit(window: requester, into: target)
        case .tile(let evicting), .switchLayout(let evicting):
            for evicted in evicting where evicted != requester {
                state.remove(window: evicted)
            }
            state.commit(window: requester, into: target)
        }
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
    }

    func testControllerMatchesPurePlanForFreshRequesters() {
        runMatrix(requester: .fresh)
    }

    func testControllerMatchesPurePlanForTiledRequesters() {
        runMatrix(requester: .tiled)
    }

    // MARK: Engine

    private enum RequesterKind {
        case fresh
        case tiled
    }

    private func runMatrix(requester kind: RequesterKind) {
        let matrices: [(layout: LayoutKind, configs: [[Slot]])] = [
            (.quarters, LayoutSwitchTests.quartersConfigs),
            (.sixths, LayoutSwitchTests.sixthsConfigs),
        ]
        for (layout, configs) in matrices {
            for config in configs {
                for target in Slot.allCases {
                    let gateway = FakeWindowGateway()
                    let controller = TilingController(gateway: gateway, pruneInterval: nil)

                    // Tile the occupancy shape: ids 1...count, in order.
                    var handles: [WindowHandle] = []
                    for slot in config {
                        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
                        handles.append(handle)
                        gateway.focused = handle
                        controller.handle(slot: slot)
                    }

                    let requesterID: WindowID
                    switch kind {
                    case .fresh:
                        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
                        handles.append(handle)
                        gateway.focused = handle
                        requesterID = WindowID(config.count + 1)
                    case .tiled:
                        gateway.focused = handles[0]
                        requesterID = 1
                    }

                    // Pure expectation over the same state.
                    var expected = TilingState()
                    for (index, slot) in config.enumerated() {
                        expected.commit(window: index + 1, into: slot)
                    }
                    let plan = expected.plan(window: requesterID, into: target)
                    applyExpected(plan, requester: requesterID, target: target, to: &expected)

                    // Real controller.
                    controller.handle(slot: target)

                    let context =
                        "\(kind) \(layout.rawValue) \(config) -> \(target.rawValue) [\(plan)]"
                    XCTAssertEqual(controller.state.occupants, expected.occupants, context)
                    XCTAssertEqual(controller.state.activeLayout, expected.activeLayout, context)
                    assertHealthy(controller.state.occupants, context: context)
                }
            }
        }
    }
}
