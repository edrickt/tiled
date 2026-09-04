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
    /// Fires when a recorder arms: announce that the next keypress will be
    /// captured, so the state change is never visual-only.
    var onArmed: ((Slot) -> Void)?
    /// Fires when a recorder disarms via tab-away with no decision.
    var onSilentCancel: ((Slot) -> Void)?

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

    /// Last committed binding, so a silent cancel (tab away mid-record)
    /// can revert the label without reaching the store.
    private var lastBinding: HotkeyBinding?

    func showBinding(_ binding: HotkeyBinding) {
        stopRecording()
        lastBinding = binding
        title = binding.label ?? "Disabled"
    }

    /// Arms the recorder; `completion` fires exactly once with the first
    /// decisive outcome (binding/clear/cancel).
    func beginRecording(completion: @escaping (HotkeyRecorder.Outcome) -> Void) {
        stopRecording()
        isRecording = true
        self.completion = completion
        title = "Press shortcut…"
        // The armed state is otherwise visual-only: the title change is
        // not announced, and a VoiceOver user gets no cue that the next
        // keypress will be captured (Esc cancels). The controller posts
        // the announcement; the button owns the moment it fires.
        onArmed?(slot)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            // Navigation keys pass through so keyboard users can tab away
            // mid-record (the button disarms via resignFirstResponder's
            // focus reset); Esc still cancels explicitly.
            if HotkeyRecorder.shouldPassThrough(event) {
                self.cancelSilently()
                return event
            }
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
    /// Honors Reduce Motion: when the user asked for less motion the shake
    /// is skipped — the VoiceOver announcement and preserved binding carry
    /// the meaning on their own.
    func shake() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
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

    /// Tabbing away mid-record disarms without deciding: the pending
    /// completion is dropped and the label reverts to the stored binding.
    /// (The controller owns the store; the button restores its own title
    /// from the last shown binding via the next reloadShortcutRows pass —
    /// here it simply stops claiming the keypress.)
    private func cancelSilently() {
        stopMonitoring()
        isRecording = false
        completion = nil
        if let lastBinding {
            title = lastBinding.label ?? "Disabled"
        }
        // Tabbing away mid-record disarms with no decision and no visual
        // trace — say so, so the state change is never silent.
        onSilentCancel?(slot)
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
