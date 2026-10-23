import AppKit
import ApplicationServices
import Darwin

// Focused repro for the status glyph's canvas resolution, on the
// user-visible surface: the status icon's accessibility line.
//
// The glyph follows the cursor's display; the menu follows focus. On a
// single display both resolutions land on the same canvas, so the live
// assertions here are the single-display invariant (the line names no
// display) and the paths the presenter split touched: seeding at first
// draw, occupancy redraw through the cursor-keyed pass, focus-move
// stability, and dedupe under same-display cursor movement. The
// cross-display behavior itself needs two attached displays and cannot
// run on this machine (see the doctor's multi-display line).
//
// Usage: HOST_PID=<pid> build/focus-suite  (see run-focus-loop.sh)

let timeout: Float = 1.0
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)

var pass = 0, fail = 0
func check(_ ok: Bool, _ label: String) {
    if ok { pass += 1; print("PASS \(label)") }
    else { fail += 1; print(">>>> FAILED: \(label)") }
}

func attr(_ el: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name, &v) == .success else { return nil }
    return v
}

func title(of el: AXUIElement) -> String { attr(el, kAXTitleAttribute as CFString) as? String ?? "?" }

func focusedAppPID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}

let hostPID: pid_t = {
    if let raw = ProcessInfo.processInfo.environment["HOST_PID"], let pid = pid_t(raw), pid > 0 {
        return pid
    }
    fatalError("HOST_PID not set")
}()

func hostWindows() -> [(el: AXUIElement, title: String)] {
    let app = AXUIElementCreateApplication(hostPID)
    AXUIElementSetMessagingTimeout(app, timeout)
    guard let v = attr(app, kAXWindowsAttribute as CFString), let arr = v as? [AXUIElement] else {
        return []
    }
    return arr.compactMap { el in (el, title(of: el)) }
}

func hostWindow(_ t: String) -> AXUIElement? { hostWindows().first { $0.title == t }?.el }

func focus(_ t: String) {
    guard let w = hostWindow(t) else { print("FATAL: no \(t)"); exit(2) }
    for attempt in 0..<4 {
        NSRunningApplication(processIdentifier: hostPID)?.activate(options: [.activateAllWindows])
        usleep(300_000)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(300_000)
        if focusedAppPID() == hostPID,
            let fw = attr(AXUIElementCreateApplication(hostPID), kAXFocusedWindowAttribute as CFString),
            CFEqual(fw as! AXUIElement, w)
        { return }
        print("focus(\(t)) attempt \(attempt + 1) refused; frontmost pid=\(focusedAppPID().map(String.init) ?? "?")")
    }
    print("FATAL: could not focus \(t)")
    exit(2)
}

// MARK: status item

func tiledStatusItem() -> AXUIElement? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.lowercased() == "tiled"
            || $0.executableURL?.lastPathComponent.lowercased() == "tiled"
    }) else { return nil }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, timeout)
    guard let extras = attr(el, kAXExtrasMenuBarAttribute as CFString) else { return nil }
    return (attr(extras as! AXUIElement, kAXChildrenAttribute as CFString) as? [AXUIElement])?.first
}

func iconDescription() -> String {
    guard let item = tiledStatusItem(),
        let desc = attr(item, kAXDescriptionAttribute as CFString) as? String
    else { return "?" }
    return desc
}

func occupiedCells() -> Int? {
    guard let range = iconDescription().range(of: "of") else { return nil }
    return iconDescription()[..<range.lowerBound].split(separator: " ").last.flatMap { Int($0) }
}

func waitFor(_ predicate: @escaping () -> Bool, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if predicate() { return true }
        usleep(150_000)
    }
    return predicate()
}

// MARK: input

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(40_000) }
func hotkey(_ keyCode: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down)
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
}
func hotkey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down)
        e?.flags = flags
        post(e)
    }
}
let optShift: CGEventFlags = [.maskAlternate, .maskShift]
let cmdCtrlOptShift: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

/// Synthetic hotkeys leave the modifier state latched; post each
/// modifier's key-up so the next combo's flags are the only ones set.
func clearLatchedModifiers() {
    let src = CGEventSource(stateID: .hidSystemState)
    for key in [58, 56, 55, 59] { // option, shift, command, control
        post(CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: false))
    }
    usleep(120_000)
}
let kVK_K: CGKeyCode = 0x28        // middle third (sixths)
let kVK_L: CGKeyCode = 0x25        // right third (sixths)
let kVK_Delete: CGKeyCode = 51     // evict focused
let kVK_Backslash: CGKeyCode = 0x2A // switch layout
let kVK_Z: CGKeyCode = 6           // undo (with cmdCtrlOptShift)

/// Moves the real cursor and posts a mouseMoved event, the shape the
/// production registrar listens for.
func moveCursor(to p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(80_000)
}

func screens() -> [CGRect] { NSScreen.screens.map(\.frame) }

// MARK: L1 — the seed at first draw

let first = waitFor({ iconDescription() != "?" }, seconds: 8) ? iconDescription() : "?"
check(first.range(of: #"^Tiled (Quarters|Sixths) layout, \d+ of \d+ slots occupied$"#, options: .regularExpression) != nil,
      "L1 glyph's line is the occupancy sentence at first draw (got: \(first))")
check(!first.contains(", on "), "L1 single display: the line names no display")

// The slot keys are per-layout; put the canvas in sixths so K/L mean cells.
if first.contains("Quarters") {
    hotkey(kVK_Backslash)
    usleep(700_000)
    check(iconDescription().contains("Sixths"), "L1a explicit switch put the canvas in sixths")
}

// MARK: L2/L3 — occupancy redraw through the cursor-keyed pass

focus("HOSTA")
hotkey(kVK_K)
check(waitFor({ occupiedCells() == 1 }, seconds: 4), "L2 tiling HOSTA lights one cell (got: \(iconDescription()))")

focus("HOSTB")
hotkey(kVK_L)
check(waitFor({ occupiedCells() == 2 }, seconds: 4), "L3 tiling HOSTB lights a second cell (got: \(iconDescription()))")

// MARK: L4 — focus moves leave the glyph alone

let beforeFocusMove = iconDescription()
focus("HOSTA")
usleep(600_000)
check(iconDescription() == beforeFocusMove,
      "L4 focus move with menu closed redraws nothing (got: \(iconDescription()))")

// MARK: L5 — same-display cursor movement never churns the glyph

let beforeMoves = iconDescription()
var moved = false
for p in [CGPoint(x: 200, y: 300), CGPoint(x: 900, y: 500), CGPoint(x: 1400, y: 800), CGPoint(x: 400, y: 200)] {
    let visible = screens().contains { $0.maxX > p.x && $0.maxY > p.y }
    guard visible else { continue }
    moveCursor(to: p)
    moved = true
}
check(moved, "L5a posted at least one same-display mouseMoved event")
usleep(400_000)
check(iconDescription() == beforeMoves,
      "L5 cursor movement inside one display dedupes to no redraw (got: \(iconDescription()))")

// MARK: L6/L7 — untile and undo move occupancy back

focus("HOSTB")
hotkey(kVK_Delete, flags: optShift)
check(waitFor({ occupiedCells() == 1 }, seconds: 4), "L6 evicting HOSTB drops to one cell (got: \(iconDescription()))")

clearLatchedModifiers()
hotkey(kVK_Z, flags: cmdCtrlOptShift)
check(waitFor({ occupiedCells() == 2 }, seconds: 4), "L7 undo restores the second cell (got: \(iconDescription()))")

// MARK: cleanup — untile everyone so the board is clean

for t in ["HOSTA", "HOSTB", "HOSTC", "HOSTD"] {
    if hostWindow(t) != nil {
        focus(t)
        hotkey(kVK_Delete, flags: optShift)
        usleep(250_000)
    }
}
check(waitFor({ occupiedCells() == 0 }, seconds: 4), "cleanup untiled every host window (got: \(iconDescription()))")

print("PASS \(pass) FAIL \(fail)")
exit(fail == 0 ? 0 : 1)
