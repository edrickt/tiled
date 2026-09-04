import AppKit

/// A shortcut-recorder button for one slot: click to arm, press a combo to
/// commit. While armed it shows "Press shortcut…" and captures the next
/// keyDown via a local event monitor; anything `HotkeyRecorder` ignores
/// (bare keys, lone modifiers) keeps it armed instead of cancelling.
///
/// Disabled slots (no binding) render as "Disabled"; armed-then-cancelled
/// restores the previous label via `showBinding`.
final class RecorderButton: NSButton {
    let slot: Slot
    private(set) var isRecording = false
    private var monitor: Any?
    private var completion: ((HotkeyRecorder.Outcome) -> Void)?

    init(slot: Slot) {
        self.slot = slot
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopMonitoring()
    }

    func showBinding(_ binding: HotkeyBinding) {
        stopRecording()
        title = binding.label ?? "Disabled"
    }

    /// Arms the recorder; `completion` fires exactly once with the first
    /// decisive outcome (binding/clear/cancel).
    func beginRecording(completion: @escaping (HotkeyRecorder.Outcome) -> Void) {
        stopRecording()
        isRecording = true
        self.completion = completion
        title = "Press shortcut…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard let outcome = HotkeyRecorder.outcome(for: event) else {
                return nil // swallow non-decisive keys, stay armed
            }
            let done = self.completion
            self.completion = nil
            self.stopRecording()
            done?(outcome)
            return nil // swallow the decisive keypress too
        }
    }

    /// Rejects a duplicate with a horizontal shake, keeping the old binding.
    func shake() {
        let original = frame.origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.05
            for i in 0..<4 {
                animator().setFrameOrigin(NSPoint(
                    x: original.x + (i % 2 == 0 ? 6 : -6), y: original.y))
            }
        } completionHandler: { [weak self] in
            self?.setFrameOrigin(original)
        }
    }

    private func stopRecording() {
        stopMonitoring()
        isRecording = false
        completion = nil
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
