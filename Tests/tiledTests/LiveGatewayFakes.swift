import ApplicationServices
@testable import tiled

/// Records the AXObserver calls the live adapter makes and delivers
/// notifications through the callback the adapter registered at create
/// time. No AXObserver, run-loop source, or Accessibility grant is
/// involved.
final class FakeAXObserverDriver: AXObserverDriver {
    final class Observer: AXObserverHandle {
        let pid: pid_t
        private(set) var notifications: [String] = []
        private(set) var runLoopSourceAdded = false

        init(pid: pid_t) {
            self.pid = pid
        }

        func record(_ notification: String) {
            notifications.append(notification)
        }

        func setRunLoopSource(_ added: Bool) {
            runLoopSourceAdded = added
        }
    }

    /// When set, observer creation fails with this status.
    var createError: AXError?
    /// Notification names whose add fails, with the status to report.
    var addFailures: [String: AXError] = [:]
    private(set) var observers: [Observer] = []
    private(set) var removedRunLoopSources: [Observer] = []
    private var onNotification: ((String, UInt) -> Void)?

    func createObserver(
        pid: pid_t, onNotification: @escaping (String, UInt) -> Void
    ) -> (status: AXError, observer: AXObserverHandle?) {
        if let createError { return (createError, nil) }
        let observer = Observer(pid: pid)
        observers.append(observer)
        self.onNotification = onNotification
        return (.success, observer)
    }

    func addNotification(
        _ notification: String, to observer: AXObserverHandle,
        element: AXUIElement?
    ) -> AXError {
        guard let observer = observer as? Observer else { return .failure }
        if let error = addFailures[notification] { return error }
        observer.record(notification)
        return .success
    }

    func addRunLoopSource(_ observer: AXObserverHandle) {
        (observer as? Observer)?.setRunLoopSource(true)
    }

    func removeRunLoopSource(_ observer: AXObserverHandle) {
        guard let observer = observer as? Observer else { return }
        observer.setRunLoopSource(false)
        removedRunLoopSources.append(observer)
    }

    /// Delivers a notification the way AX would, through the callback the
    /// gateway registered for the observer.
    func deliver(_ notification: String, token: UInt) {
        onNotification?(notification, token)
    }
}

/// A scripted window element: its frame and the answer to each AX write.
final class FakeWindowFrames: WindowFrames {
    private(set) var frameValue: CGRect?
    /// Status of each successive top-left write; `.success` after the list
    /// runs out.
    var topLeftResults: [AXError] = []
    /// Status of each successive size write; `.success` after the list
    /// runs out.
    var sizeResults: [AXError] = []
    /// Writes report success but change nothing: an app that silently
    /// ignores AX geometry writes, the dominant real-world refusal shape.
    var ignoresWrites = false
    private(set) var topLeftWrites: [CGPoint] = []
    private(set) var sizeWrites: [CGSize] = []

    init(frame: CGRect?) {
        frameValue = frame
    }

    func frame() -> CGRect? { frameValue }

    /// The AppKit top-left of the frame: the counterpart of AX's position
    /// attribute, which is a top-left point. The fake mirrors the live
    /// adapter: a position write moves the top-left, and a size write keeps
    /// it fixed (AX resize anchors the top-left). A caller that passes the
    /// frame's bottom-left origin therefore shifts the window down by its
    /// own height, exactly as the live path would.
    func topLeft() -> CGPoint? {
        frameValue.map { CGPoint(x: $0.minX, y: $0.maxY) }
    }

    func setTopLeft(_ topLeft: CGPoint) -> AXError {
        let result = nextResult(&topLeftResults)
        topLeftWrites.append(topLeft)
        if result == .success, !ignoresWrites, var frame = frameValue {
            frame.origin = CGPoint(x: topLeft.x, y: topLeft.y - frame.height)
            frameValue = frame
        }
        return result
    }

    func setSize(_ size: CGSize) -> AXError {
        let result = nextResult(&sizeResults)
        sizeWrites.append(size)
        if result == .success, !ignoresWrites, var frame = frameValue {
            let top = frame.maxY
            frame.size = size
            frame.origin.y = top - size.height
            frameValue = frame
        }
        return result
    }

    private func nextResult(_ results: inout [AXError]) -> AXError {
        results.isEmpty ? .success : results.removeFirst()
    }
}
