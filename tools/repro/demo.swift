import AppKit
import ApplicationServices

// The demo suite: the same live machinery run-repro.sh drives, paced for
// showing off instead of verifying. No assertion mirrors — every scene
// performs one headline operation and holds long enough for a screen
// recording to catch it (scripts/run-repro.sh tools/repro/demo.swift).
//
// Scene line: scattered desktop -> hotkey-tile the quarters -> live
// splitter drags -> a title-bar drag-out untile -> undo snaps the window
// back -> the layout switch to sixths -> a per-third row resize -> undo
// the resize -> evict everyone back to a scattered desktop.

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
    "sixthTopLeft": CGKeyCode(32), "sixthTopRight": CGKeyCode(31),
    "sixthBottomLeft": CGKeyCode(46), "sixthBottomRight": CGKeyCode(47),
]

func hotkey(_ slot: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: slotKeyFor[slot]!, keyDown: down)
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
}

func pressUndo() {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 6, keyDown: down)
        e?.flags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        post(e)
    }
}

func pressLayoutSwitch() {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 42, keyDown: down) // backslash
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
}

func pressEvict(_ t: String) {
    focus(t)
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down) // ⌫
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
func dragEdge(_ t: String, _ edge: String, _ delta: CGFloat) {
    guard let f = actualFrame(t) else { return }
    let center = CGPoint(x: f.midX, y: f.midY)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left))
    let steps = 10
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
        usleep(40_000)
    }
    usleep(700_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left))
    usleep(900_000)
}

/// A real cursor drag across the screen (a title-bar grab, a drop
/// wherever the hand lets go).
func drag(from: CGPoint, to: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
    let steps = 30
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
        usleep(16_000)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
    usleep(900_000)
}

func hold(_ seconds: Double, _ scene: String) {
    print("==> \(scene)")
    usleep(useconds_t(seconds * 1_000_000))
}

func tile(_ t: String, _ slot: String) {
    focus(t)
    hotkey(slot)
    usleep(900_000)
}

// MARK: the demo

hold(4.0, "a messy desktop")

tile("HOSTA", "TL")
tile("HOSTB", "TR")
tile("HOSTC", "BL")
tile("HOSTD", "BR")
hold(4.0, "hotkeys tile the quarters")

dragEdge("BL", "right", 150)
hold(2.5, "a splitter drag reshapes the column")
dragEdge("TL", "bottom", -80)
hold(2.5, "row dividers move independently")

if let f = actualFrame("HOSTA") {
    let grab = CGPoint(x: f.midX, y: f.minY + 10)
    let drop = CGPoint(x: vf.midX, y: vf.midY + 120)
    drag(from: grab, to: drop)
}
hold(4.0, "drag a tile out: it floats where dropped")

pressUndo()
hold(4.0, "undo snaps it back into its slot")

pressLayoutSwitch()
hold(3.5, "the layout switch untiles to the quarter footprint")

tile("HOSTA", "sixthTopLeft")
tile("HOSTB", "sixthTopRight")
tile("HOSTC", "sixthBottomLeft")
tile("HOSTD", "sixthBottomRight")
hold(4.0, "the same keys tile sixths")

dragEdge("sixthBottomLeft", "top", 60)
hold(3.0, "one third's row divider, the rest held")

pressUndo()
hold(3.0, "undo steps the drag back")

for t in ["HOSTA", "HOSTB", "HOSTC", "HOSTD"] {
    pressEvict(t)
    usleep(400_000)
}
hold(4.0, "evict everyone: back to a messy desktop")

print("demo done")
