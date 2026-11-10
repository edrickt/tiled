import AppKit
import ApplicationServices

// The demo suite: the same live machinery run-repro.sh drives, paced for
// showing off instead of verifying. No assertion mirrors — every step
// performs one operation and waits one uniform beat, so the recording
// has an even rhythm (scripts/run-repro.sh tools/repro/demo.swift).
//
// Line: four untiled windows -> each tiled to a quarter corner -> the
// bottom-left window dragged to the center to untile it (the top-left
// survivor reflows into the left half) and closed -> the left half's
// right edge dragged right to widen, then back to a left half -> the red
// left half swaps with the blue top right (blue takes the vacated left
// half), the blue left half swaps with the orange bottom right (orange
// takes the vacated left half) -> the blue tile fills the screen and
// returns. The demo ends on the tiled state; nothing is closed.

// MARK: AX helpers (trimmed from suite.swift)

func axPoint(_ p: CGPoint) -> AXValue? { var v = p; return AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &v) }
func axSize(_ s: CGSize) -> AXValue? { var v = s; return AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &v) }

func frame(of el: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
        let pv, let sv else { return nil }
    var p = CGPoint(), s = CGSize()
    AXValueGetValue(pv as! AXValue, AXValueType(rawValue: kAXValueCGPointType)!, &p)
    AXValueGetValue(sv as! AXValue, AXValueType(rawValue: kAXValueCGSizeType)!, &s)
    return CGRect(origin: p, size: s)
}

func setRawFrame(_ el: AXUIElement, _ f: CGRect) {
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, axPoint(f.origin)!)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, axSize(f.size)!)
}

func title(of el: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v)
    return v as? String ?? "?"
}

let hostPID: pid_t? = {
    if let raw = ProcessInfo.processInfo.environment["HOST_PID"],
        let pid = pid_t(raw), pid > 0
    {
        return pid
    }
    let hosts = NSWorkspace.shared.runningApplications.filter { app in
        app.localizedName == "host" || app.executableURL?.lastPathComponent == "host"
    }
    return hosts.sorted {
        ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast)
    }.first?.processIdentifier
}()

func hostWindows() -> [(el: AXUIElement, title: String, frame: CGRect)] {
    guard let pid = hostPID else { return [] }
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
        let arr = v as? [AXUIElement] else { return [] }
    return arr.compactMap { el in
        guard let f = frame(of: el) else { return nil }
        return (el, title(of: el), f)
    }
}

func actualFrame(_ t: String) -> CGRect? {
    hostWindows().first(where: { $0.title == t })?.frame
}

/// Closes an untiled window through its close button: after the drag-out
/// scene the floating window leaves the stage instead of idling over the
/// rest of the demo.
func closeWindow(_ t: String) {
    guard let w = hostWindows().first(where: { $0.title == t }) else { return }
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(w.el, kAXCloseButtonAttribute as CFString, &v)
    if let btn = v {
        AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
    }
    usleep(600_000)
}

// MARK: input simulation

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(40_000) }

func focus(_ t: String) {
    guard let w = hostWindows().first(where: { $0.title == t }) else { return }
    AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
    usleep(100_000)
    let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left))
    usleep(150_000)
}

let slotKeyFor: [String: CGKeyCode] = [
    "TL": CGKeyCode(32), "TR": CGKeyCode(31),
    "BL": CGKeyCode(46), "BR": CGKeyCode(47),
]

func hotkey(_ slot: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: slotKeyFor[slot]!, keyDown: down)
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
}

/// The focused window's ⌥⇧⏎ expand toggle: fills the screen, then
/// restores the frame it had before expanding.
func pressExpand(_ t: String) {
    focus(t)
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down) // ⏎
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
}

// MARK: screen metrics

let screen = NSScreen.screens[0]
let vf = screen.visibleFrame
let primaryTop = screen.frame.maxY

// MARK: gesture helpers

/// A real hand drag of one tiled edge: press first, step the frame while
/// the button is down, lift after the last tick lands (a splitter
/// commits only under a held button — see suite.swift's dragEdge).
/// A ~2.4s glide reads as a gesture in a recording instead of a jump.
func dragEdge(_ t: String, _ edge: String, _ delta: CGFloat) {
    guard let f = actualFrame(t) else { return }
    let center = CGPoint(x: f.midX, y: f.midY)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left))
    let steps = 40
    for i in 1...steps {
        let t2 = CGFloat(i) / CGFloat(steps)
        var nf = f
        switch edge {
        case "right": nf.size.width = max(f.width + delta * t2, 80)
        case "left": nf.origin.x = f.minX + delta * t2; nf.size.width = max(f.width - delta * t2, 80)
        case "top": nf.origin.y = f.minY + delta * t2; nf.size.height = max(f.height - delta * t2, 80)
        case "bottom": nf.size.height = max(f.height + delta * t2, 80)
        default: break
        }
        if let el = hostWindows().first(where: { $0.title == t })?.el {
            setRawFrame(el, nf)
        }
        usleep(60_000)
    }
    usleep(700_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left))
    usleep(900_000)
}

/// A real cursor drag across the screen: a title-bar grab, a drop
/// wherever the hand lets go — past the untile distance the window
/// untiles where dropped and the freed cells reflow.
func drag(from: CGPoint, to: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
    let steps = 60
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
        usleep(40_000)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
    usleep(900_000)
}

func tile(_ t: String, _ slot: String) {
    focus(t)
    hotkey(slot)
    usleep(900_000)
}

// MARK: the demo

// One uniform beat between every action: the recording keeps an even
// rhythm instead of grouping actions with long scene holds between
// groups. Drag gestures themselves run ~2.4s; everything else waits the
// same two seconds before the next step.
let beat: useconds_t = 2_000_000

print("==> four untiled windows")
usleep(4_000_000)

for (t, slot) in [("HOSTA", "TL"), ("HOSTB", "TR"), ("HOSTC", "BL"), ("HOSTD", "BR")] {
    tile(t, slot)
    usleep(beat)
}

print("==> drag the bottom left to the center: it untiles where dropped")
if let f = actualFrame("HOSTC") {
    drag(from: CGPoint(x: f.midX, y: f.minY + 10), to: CGPoint(x: vf.midX, y: vf.midY))
}
usleep(beat)

print("==> the floating window closes: the stage holds the three tiles")
closeWindow("HOSTC")
usleep(beat)

print("==> the left half's right edge resizes right, then settles back at a left half")
dragEdge("HOSTA", "right", 150)
usleep(beat)
dragEdge("HOSTA", "right", -180)
usleep(beat)

print("==> the red left half swaps with the blue top right")
tile("HOSTA", "TR")
usleep(beat)

print("==> the blue left half swaps with the orange bottom right")
tile("HOSTB", "BR")
usleep(beat)

print("==> the blue tile fills the screen")
pressExpand("HOSTB")
usleep(beat)

print("==> and returns to its tile")
pressExpand("HOSTB")
usleep(beat)

usleep(3_000_000)
print("demo done")
