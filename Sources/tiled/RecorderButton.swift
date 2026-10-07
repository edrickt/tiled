import AppKit

/// A shortcut-recorder button for one action (a tiling slot or an app
/// action): click to arm, press a combo to commit. While armed it shows
/// "Press shortcut…" and captures the next keyDown via a local event
/// monitor; anything `HotkeyRecorder` ignores (bare keys, lone modifiers)
/// keeps it armed instead of cancelling.
///
/// Disabled actions (no binding) render as "Disabled"; armed-then-cancelled
/// restores the previous label via `showBinding`.
final class RecorderButton: NSButton {
    let hotkeyAction: HotkeyAction
    private(set) var isRecording = false
    private var monitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private var completion: ((HotkeyRecorder.Outcome) -> Void)?
    /// Fires when a recorder arms: announce that the next keypress will be
    /// captured, so the state change is never visual-only.
    var onArmed: ((HotkeyAction) -> Void)?
    /// Fires when a recorder disarms via tab-away with no decision.
    var onSilentCancel: ((HotkeyAction) -> Void)?

    init(action: HotkeyAction) {
        self.hotkeyAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        // The row label is a separate static text with no association to
        // this button: without the next line a VoiceOver user tabbing the
        // Shortcuts tab hears anonymous buttons ("⌥⇧U, button" or worse,
        // "Disabled, button"). The button names its action; the binding is
        // the value.
        setAccessibilityLabel("\(action.title) shortcut")
        setAccessibilityValue("disabled")
    }

    /// The tiling slot this recorder drives, when it drives one.
    var slot: Slot? {
        if case .slot(let slot) = hotkeyAction { return slot }
        return nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopMonitoring()
        removeWindowCloseObserver()
    }

    /// An armed recorder must never outlive its visible surface: the key
    /// monitor swallows every keyDown, so a hidden or closed button would
    /// eat keystrokes (including ⌘Q) with nothing on screen to explain it.
    /// Tab switches and view removal arrive here with `window == nil`;
    /// the window-close observer covers the close button, where the
    /// window object (and this view) outlive the dismissal.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeWindowCloseObserver()
            if isRecording { cancelSilently() }
            return
        }
        guard windowCloseObserver == nil, let window else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.cancelSilently()
        }
    }

    private func removeWindowCloseObserver() {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
    }

    /// Last committed binding, so a silent cancel (tab away mid-record)
    /// can revert the label without reaching the store.
    private var lastBinding: HotkeyBinding?

    func showBinding(_ binding: HotkeyBinding) {
        stopRecording()
        lastBinding = binding
        title = binding.label ?? "Disabled"
        setAccessibilityValue(binding.label ?? "disabled")
    }

    /// Arms the recorder; `completion` fires exactly once with the first
    /// decisive outcome (binding/clear/cancel).
    func beginRecording(completion: @escaping (HotkeyRecorder.Outcome) -> Void) {
        stopRecording()
        isRecording = true
        self.completion = completion
        title = "Press shortcut…"
        setAccessibilityValue("recording")
        // The armed state is otherwise visual-only: the title change is
        // not announced, and a VoiceOver user gets no cue that the next
        // keypress will be captured (Esc cancels). The controller posts
        // the announcement; the button owns the moment it fires.
        onArmed?(hotkeyAction)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.routeRecordedEvent(event)
        }
    }

    /// The armed state machine's routing, extracted from the event
    /// monitor so tests can drive it without a live monitor. Returns the
    /// event to pass through, or nil to swallow. The contract: a
    /// decisive key fires the pending completion exactly once and
    /// disarms; a non-decisive key is swallowed and the button stays
    /// armed; a pass-through key (tab away) silently cancels.
    func routeRecordedEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording, completion != nil else { return event }
        // Navigation keys pass through so keyboard users can tab away
        // mid-record (`viewDidMoveToWindow` disarms when the button
        // leaves the window); Esc still cancels explicitly.
        if HotkeyRecorder.shouldPassThrough(event) {
            cancelSilently()
            return event
        }
        guard let outcome = HotkeyRecorder.outcome(for: event) else {
            return nil // swallow non-decisive keys, stay armed
        }
        let done = completion
        stopRecording() // clears completion + disarms before the callback
        done?(outcome)
        return nil // swallow the decisive keypress too
    }

    /// Rejects a duplicate with a horizontal shake, keeping the old binding.
    /// Honors Reduce Motion: when the user asked for less motion the shake
    /// is skipped: the VoiceOver announcement and preserved binding carry
    /// the meaning on their own.
    func shake() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let container = superview
        else { return }
        shakeStep(0, original: frame.origin, container: container)
    }

    /// One step of the shake, chained through sequential animation groups.
    /// Four animator calls inside a single NSAnimationContext run
    /// concurrently (they compose into one blur, not a left-right shake),
    /// so each offset gets its own group and the next starts in the
    /// previous group's completion handler.
    ///
    /// `container` pins the shake to the superview it started in: if a
    /// concurrent layout pass replaces the view (rebuild, window close)
    /// mid-shake, the remaining steps stop instead of dragging the button
    /// back to a captured origin the layout no longer agrees with.
    private func shakeStep(_ index: Int, original: NSPoint, container: NSView) {
        let offsets: [CGFloat] = [6, -6, 6, -6]
        guard superview === container else { return }
        guard index < offsets.count else {
            setFrameOrigin(original)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.05
            animator().setFrameOrigin(NSPoint(x: original.x + offsets[index], y: original.y))
        }, completionHandler: { [weak self] in
            self?.shakeStep(index + 1, original: original, container: container)
        })
    }

    private func stopRecording() {
        stopMonitoring()
        isRecording = false
        completion = nil
    }

    /// Tabbing away mid-record disarms without deciding: the pending
    /// completion is dropped and the label reverts to the stored binding.
    /// (The controller owns the store; the button restores its own title
    /// from the last shown binding via the next reloadShortcutRows pass;
    /// here it simply stops claiming the keypress.)
    private func cancelSilently() {
        stopMonitoring()
        isRecording = false
        completion = nil
        if let lastBinding {
            title = lastBinding.label ?? "Disabled"
            setAccessibilityValue(lastBinding.label ?? "disabled")
        }
        // Tabbing away mid-record disarms with no decision and no visual
        // trace: say so, so the state change is never silent.
        onSilentCancel?(hotkeyAction)
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
