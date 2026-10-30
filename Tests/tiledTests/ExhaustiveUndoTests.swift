import CoreGraphics
import XCTest
@testable import tiled

/// Exhaustive check of Tiled's undo promise: one undo applies the pushed
/// chapter exactly, and nothing else.
///
/// Scope: three windows, every slot, one visible canvas, a fake gateway
/// that accepts every write. The search starts empty and follows every
/// non-noop request until no new occupancy is reachable. Every edge is
/// replayed from scratch on the real `TilingController` and `TilingSpace`;
/// the placement rules are never reimplemented here.
///
/// The documented semantics the check encodes:
/// - every snapshot entry returns to its recorded slot;
/// - a requester with a snapshot entry returns to that slot;
/// - a requester without an entry floats at the layout's slot footprint
///   at its pre-tile origin when the chapter names it as the requester
///   (a fresh eviction), and is otherwise left where the request put it
///   (a move whose only displacement is a reflow);
/// - a switch untiles every occupant and its chapter returns the whole
///   pre-switch board, previous layout included;
/// - no other window moves.
///
/// The check is opt-in because it explores 653 boards (532 Sixths, 121
/// Quarters) through 18,818 edges and checks 11,931 chapters (~5 seconds):
/// `TILED_EXHAUSTIVE=1 swift test --filter
/// ExhaustiveUndoTests/testEveryReachableBoardUndoesItsLastDisplacement`.
/// Plain `swift test` skips it.
final class ExhaustiveUndoTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1200),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1200),
        name: "Display 1")

    private struct Session {
        let controller: TilingController
        let gateway: FakeWindowGateway
        let handles: [WindowHandle]
    }

    private struct Board: Equatable {
        var occupants: [Slot: Int]
        var layout: LayoutKind
        var frames: [Int: CGRect]

        init(occupants: [Slot: Int], layout: LayoutKind, frames: [Int: CGRect]) {
            self.occupants = occupants
            self.layout = layout
            self.frames = frames
        }

        init(occupants: [Slot: Int], frames: [Int: CGRect]) {
            self.occupants = occupants
            self.layout = occupants.isEmpty ? .sixths : (occupants.keys.first?.layout ?? .sixths)
            self.frames = frames
        }
    }

    /// One user action in a replay path. A placement presses a physical key
    /// on the named window; a switch presses the explicit layout switch,
    /// which untiles every occupant and adopts the other layout.
    private enum Step: Equatable {
        case place(window: Int, slot: Slot)
        case switchLayout
    }

    private struct Counterexample {
        var count: Int
        let signature: String
        let replay: String
        let chapter: String
        let expected: [Slot: Int]
        let undone: [Slot: Int]
        let expectedFrames: [Int: CGRect]
        let undoneFrames: [Int: CGRect]
    }

    private func makeSession() -> Session {
        let gateway = FakeWindowGateway()
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.screen] }, deathConfirmation: 0)
        let frames = [
            CGRect(x: 0, y: 0, width: 400, height: 300),
            CGRect(x: 500, y: 0, width: 400, height: 300),
            CGRect(x: 1000, y: 0, width: 400, height: 300),
        ]
        let handles = frames.map { gateway.addWindow(frame: $0) }
        return Session(controller: controller, gateway: gateway, handles: handles)
    }

    private func replay(_ steps: [Step]) -> Session {
        let session = makeSession()
        for step in steps {
            switch step {
            case .place(let index, let slot):
                session.gateway.focused = session.handles[index]
                session.controller.handle(slot: slot)
            case .switchLayout:
                // The switch acts on the focused window's canvas. Always
                // focus a handle, including on an empty board: its frame
                // names the display, so the switch lands on the same
                // canvas the placements did.
                session.gateway.focused = session.handles[0]
                session.controller.handleSwitchLayout()
            }
        }
        return session
    }

    private func canvas(_ session: Session) -> TilingSpace {
        session.controller.canvas(for: session.controller.focusedTilingSpace)
    }

    private func board(_ session: Session) -> Board {
        let canvas = canvas(session)
        var indexByID: [WindowID: Int] = [:]
        for (index, handle) in session.handles.enumerated() {
            if let id = session.controller.registeredID(for: handle) {
                indexByID[id] = index
            }
        }
        var occupants: [Slot: Int] = [:]
        for (slot, id) in canvas.state.occupants {
            if let index = indexByID[id] { occupants[slot] = index }
        }
        var frames: [Int: CGRect] = [:]
        for (index, handle) in session.handles.enumerated() {
            frames[index] = session.gateway.frame(of: handle)
        }
        return Board(
            occupants: occupants, layout: canvas.state.layout, frames: frames)
    }

    private func key(_ board: Board) -> String {
        let cells = board.occupants
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
        return "\(board.layout.rawValue)|\(cells)"
    }

    private func describe(_ path: [Step]) -> String {
        guard !path.isEmpty else { return "empty board" }
        return path.map { step in
            switch step {
            case .place(let window, let slot): "win\(window) -> \(slot.rawValue)"
            case .switchLayout: "switch"
            }
        }.joined(separator: ", ")
    }

    private func healthProblem(_ board: Board) -> String? {
        var seen: Set<TileCell> = []
        for slot in board.occupants.keys {
            for cell in slot.cells {
                if !seen.insert(cell).inserted {
                    return "cell \(cell) double-booked"
                }
            }
        }
        if Set(board.occupants.keys.map(\.layout)).count > 1 {
            return "mixed layouts on one canvas"
        }
        if let occupied = board.occupants.keys.first?.layout, occupied != board.layout {
            return "occupants in \(occupied.rawValue) on a \(board.layout.rawValue) canvas"
        }
        if Set(board.occupants.values).count != board.occupants.count {
            return "one window in two slots"
        }
        return nil
    }

    /// Build the board the pushed chapter promises: start from the board
    /// the request produced, put every snapshot entry in its recorded
    /// slot, and untile a named requester that has no entry. A requester
    /// left unnamed is the move-with-reflow case and stays where it is.
    private func expectedBoard(
        after: Board, chapter: TilingSpace.UndoChapter, session: Session,
        requesterIndex: Int, preTileFrame: CGRect?, grid: GridLayout,
        visibleFrame: CGRect
    ) -> Board {
        var occupants = after.occupants
        var frames = after.frames
        var indexByHandle: [WindowHandle: Int] = [:]
        for (index, handle) in session.handles.enumerated() {
            indexByHandle[handle] = index
        }
        for entry in chapter.snapshot {
            guard let index = indexByHandle[entry.handle] else { continue }
            // A re-placed window leaves whatever slot it holds now.
            occupants = occupants.filter { $0.value != index }
            occupants[entry.slot] = index
            frames[index] = grid.rect(for: entry.slot, in: visibleFrame)
        }
        let requesterHandle = session.handles[requesterIndex]
        let requesterHasEntry = chapter.snapshot.contains { $0.handle == requesterHandle }
        if chapter.requester != nil, !requesterHasEntry {
            occupants = occupants.filter { $0.value != requesterIndex }
            // A named requester with no entry is restored to the
            // layout's slot footprint hung from its pre-tile top edge. A zero
            // record writes nothing, so the frame stays. The footprint
            // is drawn from the layout the undo lands on: the chapter's
            // own when reconciliation adopts it, else the board's — and
            // a chapter naming a requester always carries entries, so
            // the chapter's layout decides either way.
            if let preTileFrame, preTileFrame != .zero {
                let sizing = chapter.snapshot.first?.slot.layout ?? after.layout
                frames[requesterIndex] = grid.sizedUntileFrame(
                    keepingTopOf: preTileFrame, for: sizing, in: visibleFrame)
            }
        }
        return Board(occupants: occupants, layout: after.layout, frames: frames)
    }

    private func signature(
        plan: TilePlan, requesterTiled: Bool, chapter: TilingSpace.UndoChapter,
        requesterIndex: Int, session: Session
    ) -> String {
        let kind: String
        let evicted: Int
        switch plan {
        case .tile(let e): kind = "tile"; evicted = e.count
        case .swap: kind = "swap"; evicted = 1
        case .noop: kind = "noop"; evicted = 0
        }
        let requesterHandle = session.handles[requesterIndex]
        let hasEntry = chapter.snapshot.contains { $0.handle == requesterHandle }
        return "\(kind) evicted=\(evicted) requesterTiled=\(requesterTiled) "
            + "snapshot=\(chapter.snapshot.count) "
            + "requesterSet=\(chapter.requester != nil) requesterEntry=\(hasEntry)"
    }

    private func chapterDescription(
        _ chapter: TilingSpace.UndoChapter, session: Session
    ) -> String {
        var indexByHandle: [WindowHandle: Int] = [:]
        for (index, handle) in session.handles.enumerated() {
            indexByHandle[handle] = index
        }
        let entries = chapter.snapshot.compactMap { entry -> String? in
            guard let index = indexByHandle[entry.handle] else { return nil }
            return "win\(index):\(entry.slot.rawValue)"
        }
        var indexByID: [WindowID: Int] = [:]
        for (index, handle) in session.handles.enumerated() {
            if let id = session.controller.registeredID(for: handle) {
                indexByID[id] = index
            }
        }
        let requester = chapter.requester
            .flatMap { indexByID[$0] }
            .map { "win\($0)" } ?? "nil"
        return "[\(entries.joined(separator: ", "))] requester=\(requester)"
    }

    func testEveryReachableBoardUndoesItsLastDisplacement() throws {
        guard ProcessInfo.processInfo.environment["TILED_EXHAUSTIVE"] == "1" else {
            throw XCTSkip("set TILED_EXHAUSTIVE=1 to run the exhaustive undo check")
        }
        // Self-test: the health assertion must see a board that double-books
        // a cell, or every green health result below is meaningless.
        let invalid = Board(
            occupants: [.topLeft: 0, .leftHalf: 0], frames: [:])
        XCTAssertNotNil(
            healthProblem(invalid),
            "the structural-health check did not notice a window owning overlapping cells")

        let start = Date()
        var paths: [String: [Step]] = ["sixths|": []]
        var queue = ["sixths|"]
        var edges = 0
        var undoChecks = 0
        var switches = 0
        var healthProblems: [String] = []
        var switchProblems: [String] = []
        var counterexamples: [String: Counterexample] = [:]

        while !queue.isEmpty {
            let stateKey = queue.removeFirst()
            let path = paths[stateKey]!
            let base = replay(path)
            let baseBoard = board(base)
            let baseCanvas = canvas(base)
            let beforeDepth = baseCanvas.undoStack.count
            if let problem = healthProblem(baseBoard) {
                healthProblems.append("\(describe(path)): \(problem)")
            }

            // A switch is a first-class action: from every reachable board,
            // empty or occupied, it untiles the canvas and adopts the other
            // layout. An occupied switch pushes one chapter whose undo must
            // return exactly the pre-switch board, previous layout included.
            edges += 1
            switches += 1
            let switchPath = path + [.switchLayout]
            let switched = replay(switchPath)
            let switchedBoard = board(switched)
            if let problem = healthProblem(switchedBoard) {
                healthProblems.append("\(describe(switchPath)): \(problem)")
            }
            if paths[key(switchedBoard)] == nil {
                paths[key(switchedBoard)] = switchPath
                queue.append(key(switchedBoard))
            }
            if switchedBoard.layout == baseBoard.layout {
                switchProblems.append(
                    "\(describe(path)): a switch kept the \(baseBoard.layout.rawValue) layout")
            }
            let switchedCanvas = canvas(switched)
            if baseBoard.occupants.isEmpty {
                if switchedCanvas.undoStack.count != beforeDepth {
                    switchProblems.append(
                        "\(describe(path)): a zero-window switch pushed a chapter")
                }
            } else {
                let expectedDepth = min(beforeDepth + 1, TilingSpace.undoDepth)
                if switchedCanvas.undoStack.count != expectedDepth
                    || switchedCanvas.undoStack.last?.snapshot.count
                        != baseBoard.occupants.count
                {
                    switchProblems.append(
                        "\(describe(path)): the switch did not push one complete chapter")
                } else if let chapter = switchedCanvas.undoStack.last {
                    undoChecks += 1
                    let performed = switched.controller.undoLastDisplacement()
                    let undone = board(switched)
                    assertHealthy(undone, "after undo of a switch from \(describe(path))")
                    if !performed || undone != baseBoard {
                        switchProblems.append(
                            "\(describe(path)): undo of the switch did not return "
                                + "the pre-switch board\n"
                                + "  chapter  \(chapterDescription(chapter, session: switched))\n"
                                + "  expected \(baseBoard.occupants) "
                                + "\(baseBoard.layout.rawValue)\n"
                                + "  undone   \(undone.occupants) "
                                + "\(undone.layout.rawValue)")
                    }
                }
            }

            for (index, handle) in base.handles.enumerated() {
                // An unregistered window is untiled; a sentinel never in
                // `occupants` gives the same plan answer the controller's
                // first real ID will give.
                let id = base.controller.registeredID(for: handle) ?? (-1 - index)
                // A slot key resolves only inside the canvas's stored
                // layout. The switch edge above is how the search reaches
                // the other layout; a slot press itself never switches.
                for slot in Slot.allCases where slot.layout == baseCanvas.state.layout {
                    let plan = baseCanvas.state.plan(window: id, into: slot)
                    if case .noop = plan { continue }
                    edges += 1
                    let requesterTiled = baseCanvas.state.slot(of: id) != nil
                    // A tiled requester has a record; a fresh one is
                    // recorded from its live frame when the action attaches
                    // it. A zero record writes nothing, so leave the frame.
                    let record = baseCanvas.record(of: id)
                    let preTileFrame: CGRect?
                    if let record {
                        preTileFrame = record.preTileFrame == .zero ? nil : record.preTileFrame
                    } else {
                        preTileFrame = base.gateway.frame(of: handle)
                    }
                    let placedPath = path + [.place(window: index, slot: slot)]
                    let next = replay(placedPath)
                    let nextBoard = board(next)
                    if let problem = healthProblem(nextBoard) {
                        healthProblems.append(
                            "\(describe(placedPath)): \(problem)")
                    }
                    if paths[key(nextBoard)] == nil {
                        paths[key(nextBoard)] = placedPath
                        queue.append(key(nextBoard))
                    }
                    guard beforeDepth < TilingSpace.undoDepth,
                        canvas(next).undoStack.count == beforeDepth + 1,
                        let chapter = canvas(next).undoStack.last
                    else { continue }
                    undoChecks += 1
                    let expected = expectedBoard(
                        after: nextBoard, chapter: chapter, session: next,
                        requesterIndex: index, preTileFrame: preTileFrame,
                        grid: baseCanvas.grid, visibleFrame: baseCanvas.visibleFrame)
                    let performed = next.controller.undoLastDisplacement()
                    let undone = board(next)
                    assertHealthy(undone, "after undo of \(describe(placedPath))")
                    guard !performed || undone != expected else { continue }
                    let sig = signature(
                        plan: plan, requesterTiled: requesterTiled, chapter: chapter,
                        requesterIndex: index, session: next)
                    let previous = counterexamples[sig]
                    counterexamples[sig] = Counterexample(
                        count: (previous?.count ?? 0) + 1,
                        signature: sig,
                        replay: describe(placedPath),
                        chapter: chapterDescription(chapter, session: next),
                        expected: expected.occupants,
                        undone: undone.occupants,
                        expectedFrames: expected.frames,
                        undoneFrames: undone.frames)
                }
            }
        }

        print(
            "DONE states=\(paths.count) edges=\(edges) switches=\(switches) "
                + "undoChecks=\(undoChecks) signatures=\(counterexamples.count) "
                + "elapsed=\(Date().timeIntervalSince(start))")
        XCTAssertGreaterThan(paths.count, 500, "the search explored too little")
        XCTAssertGreaterThan(undoChecks, 1000, "too few displacement chapters were undone")
        XCTAssertGreaterThan(switches, 0, "the search never exercised a switch")
        XCTAssertTrue(
            healthProblems.isEmpty,
            "Structural health failed:\n" + healthProblems.prefix(5).joined(separator: "\n"))
        XCTAssertTrue(
            switchProblems.isEmpty,
            "Switch undo failed:\n" + switchProblems.prefix(5).joined(separator: "\n"))

        if !counterexamples.isEmpty {
            let report = counterexamples.values
                .sorted { $0.signature < $1.signature }
                .map { example in
                    "\(example.signature): \(example.count) checks\n"
                        + "  replay   \(example.replay)\n"
                        + "  chapter  \(example.chapter)\n"
                        + "  expected \(example.expected)\n"
                        + "  undone   \(example.undone)\n"
                        + "  expFrames \(example.expectedFrames)\n"
                        + "  actFrames \(example.undoneFrames)"
                }
                .joined(separator: "\n\n")
            XCTFail(
                "Undo did not apply the chapter exactly on "
                    + "\(counterexamples.count) signature(s).\n\n" + report)
        }
    }

    /// Structural health is asserted inside the search; this helper keeps
    /// the message construction in one place.
    private func assertHealthy(_ board: Board, _ context: @autoclosure () -> String) {
        if let problem = healthProblem(board) {
            XCTFail("\(context()): \(problem)")
        }
    }
}
