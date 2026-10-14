import AppKit
import ApplicationServices

// Focused drag-out probe: tile a window into the TOP-LEFT SIXTH, drag it
// out by its title bar toward screen center, and assert the drag-out
// untile honored the drop. The reported failure: the drag "expanded the
// tile and snapped it back" — a neighbour grew and the dragged window
// returned to its slot instead of untileing.
//
// RED when, after a drag that clearly crossed the untile distance with
// multiple streamed ticks:
//   * the dragged window's final frame is back at (or near) its slot, or
//   * the log shows a splitter yank ("resize win") during the title drag, or
//   * the log shows a "dragend ... snapback" decision for that drag.
//
// Requires: dev tiled running with TILED_DEBUG=1 (stderr →
// /tmp/tiled-debug.log) and the host app running. Drives the real cursor.

let logPath = "/tmp/tiled-debug.log"

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

// Clear latched ⌥⇧ before every drag: a latched ⌥⇧ turns title drags into
// something else entirely and corrupts the experiment (see evict-drag-test).
let kVK_OptionClear: CGKeyCode = 58, kVK_ShiftClear: CGKeyCode = 56
func clearModifiers() {
    for key in [kVK_OptionClear, kVK_ShiftClear] {
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        up?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

func click(at p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
}

/// A title-bar drag: mouse down on the title bar, then `moves` posted
/// positions, then the release. `midPause` stops the stream for that many
/// microseconds partway through (the debounce race), `tickSleep` spaces
/// the events (fast flings coalesce AX ticks).
func titleDrag(from: CGPoint, to: CGPoint, ticks: Int = 20, tickSleep: UInt32 = 16_000, midPause: UInt32 = 0) {
    clearModifiers()
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
    for i in 1...max(ticks, 2) {
        let t = CGFloat(i) / CGFloat(max(ticks, 2))
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
        usleep(tickSleep)
        if i == max(ticks, 2) / 2, midPause > 0 { usleep(midPause) }
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
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
// Sixths family is ⌥⇧ + key (suite.swift sixthKeyFor).
let sixthKeyFor = ["TL": CGKeyCode(32), "TM": CGKeyCode(34), "BL": CGKeyCode(46)]
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
let top = screen.frame.maxY
let center = CGPoint(x: vf.midX, y: top - vf.midY)
let parks = [
    "HOSTA": CGRect(x: 60, y: 60, width: 500, height: 300),
    "HOSTB": CGRect(x: 900, y: 100, width: 500, height: 300),
    "HOSTC": CGRect(x: 900, y: 700, width: 500, height: 250),
    "HOSTD": CGRect(x: 1350, y: 420, width: 300, height: 200),
]
for (name, rect) in parks {
    if let w = hostWindows().first(where: { $0.title == name }) { setFrame(w.el, rect) }
}
usleep(300_000)

func tile(_ name: String, _ slot: String) {
    guard let w = hostWindows().first(where: { $0.title == name }) else {
        print("FATAL: \(name) missing"); exit(1)
    }
    click(at: CGPoint(x: w.frame.midX, y: w.frame.midY))
    usleep(150_000)
    hotkey(sixthKeyFor[slot]!, flags: optShift)
    usleep(900_000)
}

var (logOffset, _) = logTail(since: 0)

func snapshot(_ label: String) -> [String: CGRect] {
    var out: [String: CGRect] = [:]
    for w in hostWindows() where parks.keys.contains(w.title) { out[w.title] = w.frame }
    print("[\(label)] \(out.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  "))")
    return out
}

let tiledFrames = snapshot("pre-board")
// A verified board before anything is measured: untile, park, reset the
// splitters, tile, and check every placement.
freshBoard()
let verified = snapshot("tiled")
guard let a = verified["HOSTA"] else {
    print("FATAL: HOSTA not visible after tiling"); exit(1)
}
let slotRect = a
let grabPoint = CGPoint(x: slotRect.midX, y: slotRect.minY + 12) // title bar

/// Untiles every host window explicitly: focus it wherever it is now,
/// then ⌥⇧⌫. Two passes: an overlap can steal a click, and the second
/// pass catches what the first missed after frames spread out.
func untileAllHosts() {
    for _ in 0..<2 {
        for name in parks.keys.sorted() {
            guard let w = hostWindows().first(where: { $0.title == name }) else { continue }
            click(at: CGPoint(x: w.frame.midX, y: w.frame.minY + 12))
            usleep(150_000)
            hotkey(kVK_Delete, flags: optShift)
            usleep(400_000)
        }
    }
}

func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 8 && abs(a.minY - b.minY) < 8
        && abs(a.width - b.width) < 8 && abs(a.height - b.height) < 8
}

/// A fresh board per variant: untile everything, park, tile, and verify
/// the placements — a scrambled board poisons every observation after it.
func freshBoard() {
    untileAllHosts()
    for (name, rect) in parks {
        if let w = hostWindows().first(where: { $0.title == name }) { setFrame(w.el, rect) }
    }
    usleep(300_000)
    // Splitters persist across untiles; earlier drags may have moved them.
    // ⌥⇧R snaps them back to even splits before the board is rebuilt.
    hotkey(CGKeyCode(15), flags: optShift)
    usleep(600_000)
    tile("HOSTB", "TM")
    tile("HOSTA", "TL")
    tile("HOSTC", "BL")
    let board = hostWindows().reduce(into: [:]) { $0[$1.title] = $1.frame }
    let ok = close(board["HOSTA"] ?? .zero, tileRect(.zero, "TL"))
        && close(board["HOSTB"] ?? .zero, tileRect(.zero, "TM"))
        && close(board["HOSTC"] ?? .zero, tileRect(.zero, "BL"))
    if !ok {
        print("FATAL: board scrambled: \(board.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  "))")
        exit(1)
    }
}

/// The expected rect of a sixth on the canvas's bounds, for board checks.
func tileRect(_ bounds: CGRect, _ slot: String) -> CGRect {
    let vf = screen.visibleFrame
    let top = screen.frame.maxY
    let b = CGRect(x: 0, y: top - vf.height, width: vf.width, height: vf.height)
    let w = b.width / 3, h = b.height / 2
    switch slot {
    case "TL": return CGRect(x: b.minX, y: b.minY, width: w, height: h)
    case "TM": return CGRect(x: b.minX + w, y: b.minY, width: w, height: h)
    case "BL": return CGRect(x: b.minX, y: b.minY + h, width: w, height: h)
    default: return .zero
    }
}

func runVariant(_ name: String, ticks: Int, tickSleep: UInt32, midPause: UInt32, repeat count: Int = 1) {
    for round in 1...count {
        print("\n== variant: \(name) (round \(round)) ==")
        var (offset, _) = logTail(since: 0)
    titleDrag(from: grabPoint, to: center, ticks: ticks, tickSleep: tickSleep, midPause: midPause)
    usleep(1_500_000) // drag-end decision + any reassert land
    let (_, tail) = logTail(since: offset)

    let after = hostWindows()
    let aFrame = after.first(where: { $0.title == "HOSTA" })?.frame
    guard let aFrame else { print("FATAL: HOSTA gone"); exit(1) }
    print("[after] HOSTA=\(aFrame)")

    var reds: [String] = []
    // The drop is the placement: HOSTA must sit at the drop point, not
    // back in its slot. Slot proximity is the reported snapback.
    let backInSlot = abs(aFrame.midX - slotRect.midX) < 40 && abs(aFrame.midY - slotRect.midY) < 40
    if backInSlot { reds.append("HOSTA snapped back into its slot") }
    // A title-bar drag never moves splitters: any "resize win" line in
    // the drag's log window is a misread edge drag (tile expansion).
    let yanks = tail.components(separatedBy: "\n").filter { $0.contains("resize win") }
    if !yanks.isEmpty {
        reds.append("splitter yanked during title drag")
        print(yanks.joined(separator: "\n"))
    }
    let snapbacks = tail.components(separatedBy: "\n").filter { $0.contains("dragend") && $0.contains("snapback") }
    if !snapbacks.isEmpty {
        reds.append("dragend decided snapback")
        print(snapbacks.joined(separator: "\n"))
    }
    let untiled = tail.contains("drag-untile win")
    print(untiled ? "untile marker present" : "untile marker MISSING")

    if reds.isEmpty {
            print("VERDICT [\(name) r\(round)]: green")
        } else {
            print("VERDICT [\(name) r\(round)]: RED — \(reds.joined(separator: "; "))")
            print("--- log tail ---")
            print(tail.suffix(2000))
        }

        freshBoard()
    }
}

freshBoard()

// The matrix: each variant is a hypothesis about the occasional trigger.
runVariant("straight drag to center", ticks: 20, tickSleep: 16_000, midPause: 0)
runVariant("fast fling (coalesced ticks)", ticks: 3, tickSleep: 10_000, midPause: 0, repeat: 5)
runVariant("mid-drag pause past the debounce", ticks: 20, tickSleep: 16_000, midPause: 700_000)
runVariant("slow crawl", ticks: 30, tickSleep: 60_000, midPause: 0)
runVariant("drag right after tiling (echo window)", ticks: 20, tickSleep: 16_000, midPause: 0)

print("\nDONE")
exit(0)
