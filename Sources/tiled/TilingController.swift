import AppKit

/// Glues the pure `TilingState` to real windows via AX.
///
/// Owns the window registry (WindowID -> AXUIElement + pre-tile frame) and
/// enforces the eviction semantics decided in design:
/// - Tiling over an occupied slot evicts the occupant(s) (restores their
///   pre-tile floating frames).
/// - Dragging a window out of its tile is a later milestone; for now untile
///   happens via hotkey toggle (same slot key) or eviction.
final class TilingController {
    private(set) var state = TilingState()

    private struct Record {
        let element: AXUIElement
        let pid: pid_t
        var preTileFrame: CGRect
    }

    private var records: [WindowID: Record] = [:]
    private var nextID: WindowID = 1

    /// Called after any state change (for menu refresh).
    var onChange: (() -> Void)?

    // MARK: Hotkey entry point

    func handle(slot: Slot) {
        pruneDeadWindows()
        guard let focused = AXKit.focusedWindow() else { return }
        let id = windowID(for: focused.element, pid: focused.pid)

        switch state.plan(window: id, into: slot) {
        case .untile:
            untile(window: id)
        case .tile(let evicting):
            for evicted in evicting {
                untile(window: evicted)
            }
            place(window: id, into: slot)
        }
        onChange?()
    }

    // MARK: Placement

    private func place(window id: WindowID, into slot: Slot) {
        guard var record = records[id] else { return }
        if state.slot(of: id) == nil {
            // First tiling: remember where to restore when untiled.
            // A window moving between overlapping slots (e.g. Left -> BottomLeft)
            // keeps its original pre-tile frame.
            record.preTileFrame = AXKit.frame(of: record.element) ?? record.preTileFrame
            records[id] = record
        }
        state.commit(window: id, into: slot)
        applyLayout(for: id)
    }

    private func untile(window id: WindowID) {
        if let record = records[id], record.preTileFrame != .zero {
            AXKit.setFrame(record.element, to: record.preTileFrame)
        }
        records[id] = nil
        state.remove(window: id)
    }

    /// Applies `id`'s slot rect on the screen the window currently lives on.
    private func applyLayout(for id: WindowID) {
        guard let record = records[id], let slot = state.slot(of: id) else { return }
        let current = AXKit.frame(of: record.element) ?? record.preTileFrame
        let screen = NSScreen.screens.first {
            $0.visibleFrame.contains(CGPoint(x: current.midX, y: current.midY))
        } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        AXKit.setFrame(record.element, to: slot.rect(in: bounds))
    }

    // MARK: Registry

    private func windowID(for element: AXUIElement, pid: pid_t) -> WindowID {
        for (id, record) in records where CFEqual(record.element, element) {
            return id
        }
        let id = nextID
        nextID += 1
        records[id] = Record(element: element, pid: pid, preTileFrame: .zero)
        return id
    }

    /// Drops records whose AX element is gone (window closed, app quit).
    /// Called lazily before each hotkey; proper AXObserver-driven cleanup is
    /// a later milestone.
    private func pruneDeadWindows() {
        for (id, record) in records where !AXKit.isAlive(record.element) {
            records[id] = nil
            state.remove(window: id)
        }
    }

    // MARK: Bulk operations

    func untileAll() {
        pruneDeadWindows()
        for id in state.tiledWindows {
            untile(window: id)
        }
        onChange?()
    }

    // MARK: Presentation

    struct TiledWindowInfo {
        let slot: Slot
        let appName: String?
    }

    var tiledWindowsInfo: [TiledWindowInfo] {
        state.occupants
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { slot, id in
                let appName = records[id].flatMap {
                    NSRunningApplication(processIdentifier: $0.pid)?.localizedName
                }
                return TiledWindowInfo(slot: slot, appName: appName)
            }
    }

    var isTrusted: Bool { AXKit.isTrusted }
}
