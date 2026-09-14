import AppKit
import ApplicationServices
import Darwin

// End-to-end repro for window-death handling, on the user-visible
// surface: the status icon's occupancy and the survivor's frame.
//
// MODE=kill-app (default): tile two host windows (middle + right third),
// then kill the whole host app. Regression it guards: a killed app's AX
// answers read `.cannotComplete` (not `.invalidUIElement`), and
// classifying that as `.unknown` — which never prunes — left the slots
// held and the icon showing windows that were not there. A killed
// process has no notifications left to send, so this leg releases on
// the prune cadence (5s tick + 3s confirmation). Expected: icon 0 of 6.
//
// MODE=close-window: close one host window through AX while the process
// stays alive. This is the reported gesture's shape (Firefox closes the
// window a dragged tab left), and the reported bug: the slot used to sit
// until the prune cadence, ~10s. It must release as soon as the OS
// reports the element destroyed, so this leg asserts a sub-second
// release. The right survivor reflows into the right two-thirds, which
// lights the same four icon cells a ghost would — coverage, not
// occupancy — so the suite asserts the survivor's frame too.
//
// Usage: HOST_PID=<pid> MODE=<mode> build/focus-suite  (see run-focus-loop.sh)

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

func frame(of el: AXUIElement) -> CGRect? {
    guard let pv = attr(el, kAXPositionAttribute as CFString),
        let sv = attr(el, kAXSizeAttribute as CFString)
    else { return nil }
    var p = CGPoint(), s = CGSize()
    AXValueGetValue(pv as! AXValue, AXValueType(rawValue: kAXValueCGPointType)!, &p)
    AXValueGetValue(sv as! AXValue, AXValueType(rawValue: kAXValueCGSizeType)!, &s)
    return CGRect(origin: p, size: s)
}

func setFrame(_ el: AXUIElement, origin: CGPoint, size: CGSize) {
    var p = origin, s = size
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}

func title(of el: AXUIElement) -> String { attr(el, kAXTitleAttribute as CFString) as? String ?? "?" }

/// Frontmost app, the way the repro can trust it.
///
/// The system-wide `kAXFocusedApplicationAttribute` read is how Tiled
/// resolves the requester, but it returns .cannotComplete outright while
/// Terminal holds Secure Keyboard Entry — with any app frontmost. The
/// workspace's answer is equivalent for this check, and Tiled's own read
/// works whenever the frontmost app is the host (verified by the repro
/// tiling the host windows successfully).
func focusedAppPID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}

let hostPID: pid_t = {
    if let raw = ProcessInfo.processInfo.environment["HOST_PID"], let pid = pid_t(raw), pid > 0 {
        return pid
    }
    fatalError("HOST_PID not set")
}()
let mode = ProcessInfo.processInfo.environment["MODE"] ?? "kill-app"

func hostWindows() -> [(el: AXUIElement, title: String, frame: CGRect)] {
    let app = AXUIElementCreateApplication(hostPID)
    AXUIElementSetMessagingTimeout(app, timeout)
    guard let v = attr(app, kAXWindowsAttribute as CFString), let arr = v as? [AXUIElement] else {
        return []
    }
    return arr.compactMap { el in
        guard let f = frame(of: el) else { return nil }
        return (el, title(of: el), f)
    }
}

func hostWindow(_ t: String) -> AXUIElement? { hostWindows().first { $0.title == t }?.el }

/// Focus without a synthetic mouse: activate the app, set its focused
/// window, then verify both. Fatal on failure, because a hotkey pressed
/// on the wrong focus tiles a real user app.
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
let kVK_K: CGKeyCode = 0x28  // middle third
let kVK_L: CGKeyCode = 0x25  // right third

// MARK: 1. park + tile middle and right thirds

for w in hostWindows() {
    switch w.title {
    case "HOSTA": setFrame(w.el, origin: CGPoint(x: 300, y: 400), size: CGSize(width: 600, height: 350))
    case "HOSTB": setFrame(w.el, origin: CGPoint(x: 900, y: 400), size: CGSize(width: 500, height: 350))
    case "HOSTC": setFrame(w.el, origin: CGPoint(x: 300, y: 800), size: CGSize(width: 300, height: 200))
    case "HOSTD": setFrame(w.el, origin: CGPoint(x: 620, y: 800), size: CGSize(width: 300, height: 200))
    default: break
    }
}
usleep(400_000)

focus("HOSTA")
hotkey(kVK_K)
usleep(900_000)
focus("HOSTB")
hotkey(kVK_L)
usleep(900_000)

let screenWidth = NSScreen.screens[0].frame.width
let thirdW = screenWidth / 3
func isThird(_ f: CGRect?, at column: Int) -> Bool {
    guard let f else { return false }
    return abs(f.width - thirdW) < 8 && abs(f.minX - CGFloat(column) * thirdW) < 8
}
check(isThird(hostWindow("HOSTA").flatMap(frame(of:)), at: 1), "HOSTA tiled in the middle third")
check(isThird(hostWindow("HOSTB").flatMap(frame(of:)), at: 2), "HOSTB tiled in the right third")
let tiled = occupiedCells()
print("after tiling: \(iconDescription())")
check(tiled == 4, "icon shows 4 of 6 cells occupied (two thirds)")
guard tiled == 4 else { print("FATAL: invalid repro state"); exit(2) }

// MARK: 2. destroy the window(s)

switch mode {
case "close-window":
    guard let w = hostWindow("HOSTA"), let btn = attr(w, kAXCloseButtonAttribute as CFString) else {
        print("FATAL: no close button"); exit(2)
    }
    print("closing HOSTA through AX; the process stays alive")
    AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
case "kill-app":
    print("SIGKILL the whole host app (pid \(hostPID))")
    kill(hostPID, SIGKILL)
default:
    print("FATAL: unknown MODE \(mode)"); exit(2)
}
usleep(500_000)

if mode == "close-window" {
    check(hostWindow("HOSTA") == nil, "HOSTA is gone")
    check(hostWindow("HOSTB") != nil, "HOSTB kept the process alive")
} else {
    check(kill(hostPID, 0) != 0, "host process is gone")
}

// MARK: 3. the icon must release the dead slots on its own

print("waiting for the dead window to release its cells…")
let reflowTarget = CGRect(x: thirdW, y: 0, width: 2 * thirdW, height: 1019)
func settled() -> Bool {
    switch mode {
    case "close-window":
        // The right-third survivor absorbs the freed middle column into
        // the right two-thirds slot. That frame is the proof the slot
        // released; the icon alone cannot tell a grown survivor from a
        // ghost, since both light the same cells.
        guard let f = hostWindow("HOSTB").flatMap(frame(of:)) else { return false }
        return abs(f.minX - reflowTarget.minX) < 8 && abs(f.width - reflowTarget.width) < 8
    default:
        return occupiedCells() == 0
    }
}
/// Budget for a window the OS already reported destroyed: the release
/// must not wait for the prune timer (5s) or its confirmation (3s). The
/// probe cadence here is 0.5s, so 2s leaves ample room for the reflow
/// write while still failing loudly on a poll-paced release.
let promptBudget: TimeInterval = 2.0
let start = Date()
var releasedAt: TimeInterval?
while Date().timeIntervalSince(start) < 40 {
    if settled() {
        releasedAt = Date().timeIntervalSince(start)
        break
    }
    usleep(500_000)
}
if let releasedAt {
    pass += 1
    print("PASS slot released after \(String(format: "%.2f", releasedAt))s: \(iconDescription())")
    if mode == "close-window" {
        // The reported bug, stated as a deadline: a closed window's tile
        // must be gone in about a second, not after the prune cadence.
        check(
            releasedAt <= promptBudget,
            String(format: "released within %.0fs (%.2fs)", promptBudget, releasedAt))
    }
} else {
    fail += 1
    print(">>>> FAILED: after 40s the dead slot is still held: \(iconDescription())")
}
if mode == "close-window" {
    let survivor = hostWindow("HOSTB").flatMap(frame(of:))
    print("survivor HOSTB frame=\(survivor.map(String.init(describing:)) ?? "gone")")
}
print("RESULT pass=\(pass) fail=\(fail)")
exit(fail == 0 ? 0 : 1)
