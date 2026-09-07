import AppKit
import ApplicationServices

// Focused eviction test: tile three windows (TL, BL, TR), drag the LEFT
// half's horizontal divider, then watch the UNINVOLVED window (TR) for
// verify-rollback eviction. The drag re-pushes every occupant of the
// screen; TR's rect is unchanged by this edge, so its re-push is a no-op
// write. If TR's app emits no AX notification for a no-op write, the
// convergence check at +3.5s reads .ignored and rolls TR back — eviction
// seconds after a drag the window wasn't even part of.
//
// Requires: tiled with TILED_DEBUG=1 (stderr → /tmp/tiled-debug.log), host app running.

let logPath = "/tmp/tiled-debug.log"
let tol: CGFloat = 3.0

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

func setFrame(_ el: AXUIElement, _ f: CGRect) {
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, axPoint(f.origin)!)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, axSize(f.size)!)
}

func title(of el: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v)
    return v as? String ?? "?"
}

func hostWindows() -> [(el: AXUIElement, title: String, frame: CGRect)] {
    guard let pid = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == "host" || $0.executableURL?.lastPathComponent == "host"
    })?.processIdentifier else { return [] }
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
        let arr = v as? [AXUIElement] else { return [] }
    return arr.compactMap { el in
        guard let f = frame(of: el) else { return nil }
        return (el, title(of: el), f)
    }
}

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(40_000) }

// Clear any latched modifier state before synthesizing input: hotkey
// events below carry ⌥⇧ flags, and a latched ⌥⇧ turns every subsequent
// synthesized edge drag into a symmetric aspect-preserving resize —
// corrupting the whole experiment (observed: windows uniformly scaled
// about their center during "vertical" drags).
let kVK_OptionClear: CGKeyCode = 58, kVK_ShiftClear: CGKeyCode = 56
for key in [kVK_OptionClear, kVK_ShiftClear] {
    let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
    up?.post(tap: .cghidEventTap)
    usleep(30_000)
}
func click(at p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
}
func drag(from: CGPoint, to: CGPoint) {
    // Clear latched ⌥⇧ (re-latched by every hotkey post) right before
    // the drag, or the native resize behaves as a symmetric
    // aspect-preserving ⌥⇧-drag and corrupts the experiment.
    for key in [kVK_OptionClear, kVK_ShiftClear] {
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        up?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
    for i in 1...20 {
        let t = CGFloat(i) / 20.0
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
        usleep(16_000)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
}
func hotkey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    post(down)
    let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    post(up)
}

let optShift: CGEventFlags = [.maskAlternate, .maskShift]
let kVK_U: CGKeyCode = 0x20   // TL
let kVK_M: CGKeyCode = 0x2E   // BL
let kVK_O: CGKeyCode = 0x1F   // TR
let kVK_Delete: CGKeyCode = 51

func logTail(since offset: Int) -> (newOffset: Int, text: String) {
    guard let data = FileManager.default.contents(atPath: logPath),
        let text = String(data: data, encoding: .utf8) else { return (offset, "") }
    let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
    return (text.count, String(text[start...]))
}

// MARK: setup

guard !hostWindows().isEmpty else { print("FATAL: host app not running"); exit(1) }

let screen = NSScreen.screens[0]
let vf = screen.visibleFrame
let primaryTop = screen.frame.maxY
let midX = vf.midX, midY = primaryTop - vf.midY
// Parking rects: pairwise disjoint and clear of every quarter tile the
// other windows will occupy, so clicks never land on a tiled window.
let parks = [
    "HOSTA": CGRect(x: 60, y: 60, width: 500, height: 300),
    "HOSTB": CGRect(x: 900, y: 100, width: 500, height: 300),
    "HOSTC": CGRect(x: 900, y: 700, width: 500, height: 250),
]
for (name, rect) in parks {
    if let w = hostWindows().first(where: { $0.title == name }) { setFrame(w.el, rect) }
}
usleep(300_000)

// Untile anything left over from previous runs.
for _ in 0..<3 { hotkey(kVK_Delete, flags: optShift); usleep(250_000) }

// Log offset snapshot BEFORE tiling: the placement check below scans
// everything from here.
var (logOffset, _) = logTail(since: 0)

func tile(_ name: String, _ key: CGKeyCode) {
    guard let w = hostWindows().first(where: { $0.title == name }) else {
        print("FATAL: \(name) missing"); exit(1)
    }
    click(at: CGPoint(x: w.frame.midX, y: w.frame.midY))
    usleep(150_000)
    hotkey(key, flags: optShift)
    usleep(700_000)
}
tile("HOSTA", kVK_U)
tile("HOSTB", kVK_M)
tile("HOSTC", kVK_O)

let (_, placedLog) = logTail(since: logOffset)
guard placedLog.contains("place win"), placedLog.components(separatedBy: "place win").count >= 4 else {
    print("FATAL: placements missing from log:"); print(placedLog.suffix(600)); exit(1)
}
logOffset = logTail(since: 0).newOffset

let before = hostWindows()
for w in before where parks.keys.contains(w.title) {
    print("tiled \(w.title): \(w.frame)")
}

// MARK: drag the left half's horizontal divider up 80px (HOSTB's top edge)

guard let b = before.first(where: { $0.title == "HOSTB" }) else { print("FATAL: HOSTB missing"); exit(1) }
let edgeY = b.frame.minY + 1 // AX coords: minY is the top edge
drag(from: CGPoint(x: b.frame.midX, y: edgeY), to: CGPoint(x: b.frame.midX, y: edgeY - 80))
usleep(1_000_000)

let afterDrag = hostWindows()
for w in afterDrag where parks.keys.contains(w.title) {
    print("after drag \(w.title): \(w.frame)")
}

// MARK: watch the uninvolved window for 8s

var red = false
for tick in 1...16 {
    usleep(500_000)
    let (_, tail) = logTail(since: logOffset)
    if tail.contains("verify FAILED") || tail.contains("prune win") || tail.contains("drag-untile") {
        print("RED at +\(String(format: "%.1f", Double(tick) * 0.5))s — untile marker fired:")
        print(tail.suffix(800))
        red = true
        break
    }
}
print(red ? "VERDICT: RED (eviction after drag)" : "VERDICT: green (no eviction in 8s)")
exit(red ? 2 : 0)
