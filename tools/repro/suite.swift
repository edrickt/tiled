import AppKit
import ApplicationServices

// Comprehensive end-to-end test suite for tiled.
// Simulates user input: clicks + global hotkeys for tiling, AX frame
// mutations (step-wise, like a real drag) for resizing/moving.
// Mirrors the controller's rules and verifies every window after each step.

let tol: CGFloat = 2.0
var pass = 0, fail = 0

// MARK: AX helpers

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
    return CGRect(origin: p, size: s) // AX coords (top-left origin)
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

/// The host app this run drives. The script passes its pid, because more
/// than one instance can be alive (a leftover from an interrupted run) and
/// then "first match" can resolve to the wrong app: the suite would read
/// and move that app's windows while the window manager tiles the other
/// one's, which looks exactly like a broken layout. Without the env var,
/// the most recently launched host wins.
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

func closeWindow(_ t: String) {
    guard let w = hostWindows().first(where: { $0.title == t }) else { return }
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(w.el, kAXCloseButtonAttribute as CFString, &v)
    if let btn = v {
        AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
    }
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

/// The eleven shared ⌥⇧ slot keycodes. Both layouts use the same physical
/// key: quarters simply has no slot for five of them. The `LH`/`RH` aliases
/// keep the older quarters case names readable beside the sixths names.
let slotKeyFor: [String: CGKeyCode] = [
    "TL": CGKeyCode(32), "TM": CGKeyCode(34), "TR": CGKeyCode(31),
    "BL": CGKeyCode(46), "BM": CGKeyCode(43), "BR": CGKeyCode(47),
    "LH": CGKeyCode(38), "L": CGKeyCode(38),
    "M": CGKeyCode(40),
    "RH": CGKeyCode(37), "R": CGKeyCode(37),
    "L2": CGKeyCode(4), "R2": CGKeyCode(41),
]

func hotkey(_ slot: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: slotKeyFor[slot]!, keyDown: down)
        // One modifier set for both layouts: the same key means the same
        // position whether the canvas is in quarters or sixths.
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
}

/// The explicit layout switch, `⌥⇧\`. A slot key never switches; this is
/// the one action that does.
func switchLayout() {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 42, keyDown: down) // backslash
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
    usleep(900_000)
}

/// The sixths family shares the same physical keys and modifiers as
/// quarters; this alias keeps the sixths cases reading as sixths.
func sixthHotkey(_ slot: String) {
    hotkey(slot)
}

/// Tiles into a sixths slot and records it. Deliberately not `doTile`:
/// that helper carries the quarters eviction algebra, and this scenario
/// keeps the board to disjoint sextants so the app's sixths rules are
/// asserted through frames instead of a second occupancy model.
func doTileSixths(_ t: String, _ key: String, _ slot: String) {
    focus(t)
    sixthHotkey(key)
    usleep(900_000)
    tiled[t] = slot
}

func pressUndo() {
    let src = CGEventSource(stateID: .hidSystemState)
    // ⌃⌥⇧⌘Z: the app's fixed undo, global so it works from anywhere.
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 6, keyDown: down)
        e?.flags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        post(e)
    }
}

/// Evicts a tiled window with the app's ⌥⇧⌫: it leaves the grid and
/// returns to its pre-tile frame, which `verify` then asserts.
@discardableResult
func evict(_ t: String) -> Bool {
    guard tiled[t] != nil else { return false }
    focus(t)
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down) // ⌫
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
    usleep(900_000)
    untileMirror(t)
    return true
}

// MARK: screen metrics

let screen = NSScreen.screens[0]
let vf = screen.visibleFrame // AppKit
let primaryTop = screen.frame.maxY
func axRect(_ appkit: CGRect) -> CGRect {
    CGRect(x: appkit.minX, y: primaryTop - appkit.maxY, width: appkit.width, height: appkit.height)
}

// MARK: driver model (mirrors the controller)

var tiled: [String: String] = [:]        // title -> slot
var preTile: [String: CGRect] = [:]      // title -> AX frame captured at first tile
var col: CGFloat = 0.5
// One column split, but a row split per column: the app keeps
// `leftRowSplit` and `rightRowSplit` apart, so dragging the left
// column's row divider never moves the right column's. A single shared
// `row` here made every later scenario drift from the app on purpose.
var rowL: CGFloat = 0.5, rowR: CGFloat = 0.5

// Sixths keeps its own fractions (a layout switch never inherits the
// other layout's geometry): two vertical dividers that start at equal
// thirds, and one row divider per third — `sixthsLeftRowSplit`,
// `sixthsMiddleRowSplit`, `sixthsRightRowSplit`.
var sixthsL: CGFloat = 1.0 / 3.0, sixthsR: CGFloat = 2.0 / 3.0
var sixthsRowL: CGFloat = 0.5, sixthsRowM: CGFloat = 0.5, sixthsRowR: CGFloat = 0.5
let sixthsColumnClamp: ClosedRange<CGFloat> = 0.1...0.9

/// Sixths slot rects, mirroring the app's own line formulas: the left
/// sixth spans [screen left, sixthsLeftSplit], the middle spans
/// [sixthsLeftSplit, sixthsRightSplit], the right spans
/// [sixthsRightSplit, screen right]; thirds and two-thirds use the same
/// lines, and the row divider is the one belonging to the slot's third.
/// (A slot ending at the screen's right edge rides the right row split,
/// which is why the right two-thirds uses `sixthsRowR`.)
func sixthsColumns(_ slot: String) -> (CGFloat, CGFloat) {
    switch slot {
    case "sixthTopLeft", "sixthBottomLeft", "sixthLeft": return (0, sixthsL)
    case "sixthTopMiddle", "sixthBottomMiddle", "sixthMiddle": return (sixthsL, sixthsR)
    case "sixthTopRight", "sixthBottomRight", "sixthRight": return (sixthsR, 1)
    case "sixthsLeftTwoThirds": return (0, sixthsR)
    case "sixthsRightTwoThirds": return (sixthsL, 1)
    default: fatalError("bad sixths slot: \(slot)")
    }
}

func sixthsRowSplit(_ slot: String) -> CGFloat {
    switch slot {
    case "sixthTopLeft", "sixthBottomLeft", "sixthLeft", "sixthsLeftTwoThirds":
        return sixthsRowL
    case "sixthTopMiddle", "sixthBottomMiddle", "sixthMiddle":
        return sixthsRowM
    default:
        return sixthsRowR
    }
}

func sixthsRect(_ slot: String) -> CGRect {
    let (c0, c1) = sixthsColumns(slot)
    let row = sixthsRowSplit(slot)
    let x0 = vf.minX + c0 * vf.width
    let x1 = vf.minX + c1 * vf.width
    let ySplit = vf.minY + row * vf.height
    let rect: CGRect
    switch slot {
    case "sixthTopLeft", "sixthTopMiddle", "sixthTopRight":
        rect = CGRect(x: x0, y: ySplit, width: x1 - x0, height: vf.maxY - ySplit)
    case "sixthBottomLeft", "sixthBottomMiddle", "sixthBottomRight":
        rect = CGRect(x: x0, y: vf.minY, width: x1 - x0, height: ySplit - vf.minY)
    default:
        rect = CGRect(x: x0, y: vf.minY, width: x1 - x0, height: vf.height)
    }
    return axRect(rect)
}

let sixthsSlots = [
    "sixthTopLeft", "sixthTopMiddle", "sixthTopRight",
    "sixthBottomLeft", "sixthBottomMiddle", "sixthBottomRight",
    "sixthLeft", "sixthMiddle", "sixthRight",
    "sixthsLeftTwoThirds", "sixthsRightTwoThirds",
]

let quads: [String: Set<String>] = [
    "TL": ["tl"], "TR": ["tr"], "BL": ["bl"], "BR": ["br"],
    "LH": ["tl", "bl"], "RH": ["tr", "br"],
]
/// The slots whose cells can exactly equal a free region, in declaration
/// order (the app picks the first match the same way). Quarters is the
/// refinement's 4-cell quotient — left/right by top/bottom — which is
/// faithful here because every slot is a union of these cells.
let quadSlots = ["TL", "TR", "BL", "BR", "LH", "RH"]
let allQuadCells: Set<String> = ["tl", "tr", "bl", "br"]
func overlaps(_ a: String, _ b: String) -> Bool { !quads[a]!.isDisjoint(with: quads[b]!) }

func gridRect(_ slot: String) -> CGRect {
    if sixthsSlots.contains(slot) { return sixthsRect(slot) }
    let x = vf.minX + col * vf.width
    let row = (slot == "TR" || slot == "BR") ? rowR : rowL
    let y = vf.minY + row * vf.height
    let r: CGRect
    switch slot {
    case "TL": r = CGRect(x: vf.minX, y: y, width: x - vf.minX, height: vf.maxY - y)
    case "TR": r = CGRect(x: x, y: y, width: vf.maxX - x, height: vf.maxY - y)
    case "BL": r = CGRect(x: vf.minX, y: vf.minY, width: x - vf.minX, height: y - vf.minY)
    case "BR": r = CGRect(x: x, y: vf.minY, width: vf.maxX - x, height: y - vf.minY)
    case "LH": r = CGRect(x: vf.minX, y: vf.minY, width: x - vf.minX, height: vf.height)
    case "RH": r = CGRect(x: x, y: vf.minY, width: vf.maxX - x, height: vf.height)
    default: fatalError("bad slot")
    }
    return axRect(r)
}

func actualFrame(_ t: String) -> CGRect? {
    hostWindows().first(where: { $0.title == t })?.frame
}

func untileMirror(_ t: String) { tiled[t] = nil }

/// Whether a frame is one of the grid's slot rects under the current
/// splitters. A window the app still has tiled reports one of these.
func isOnGrid(_ f: CGRect) -> Bool {
    (["TL", "TR", "BL", "BR", "LH", "RH"] + sixthsSlots).contains { close(f, gridRect($0)) }
}

func doTile(_ t: String, _ slot: String) {
    let wasTiled = tiled[t] != nil
    let preFrame = actualFrame(t)
    focus(t)
    hotkey(slot)
    usleep(900_000)
    if tiled[t] == slot { // same-tile re-press is a no-op
        return
    }
    let blockers = tiled.filter { $0.key != t && overlaps($0.value, slot) }

    // Swap: the requester is already tiled, exactly one window blocks the
    // target, and the tile it vacates is disjoint from the target. Nobody
    // is untiled: the blocker takes the vacated tile and focus follows it.
    if wasTiled, blockers.count == 1, !overlaps(tiled[t]!, slot) {
        let (blocked, _) = blockers.first!
        tiled[blocked] = tiled[t]!
        tiled[t] = slot
        return
    }

    // Re-house is decided before anything moves, exactly as the app does
    // it: the cells nobody occupies — the target plus every other
    // window's tile, with the requester still in the tile it is leaving —
    // must be exactly one whole slot, and a lone evictee moves into it
    // instead of untangling. Two evictees never re-house.
    var rehouse: (window: String, home: String)?
    if blockers.count == 1 {
        let evictee = blockers.first!.key
        var occupied = quads[slot]!
        for (other, s) in tiled where other != t && other != evictee {
            occupied.formUnion(quads[s]!)
        }
        let free = allQuadCells.subtracting(occupied)
        if let home = quadSlots.first(where: { quads[$0] == free }) {
            rehouse = (evictee, home)
        }
    }

    for (other, _) in blockers {
        untileMirror(other)
    }
    if let (evictee, home) = rehouse {
        tiled[evictee] = home
    }
    // Only a really-floating frame becomes a restore target: a grid rect
    // means the app still has the window tiled (the mirror can lag the
    // app), and recording it would later assert a restore the app
    // correctly never performs.
    if !wasTiled, let f = preFrame, !isOnGrid(f) { preTile[t] = f }
    tiled[t] = slot
}

// Simulated drag: mutate the dragged window's frame via AX in steps.
// The controller receives the same notification stream as a native drag.
func dragEdge(_ t: String, _ edge: String, _ delta: CGFloat) {
    guard let slot = tiled[t], let f = actualFrame(t) else { return }
    let steps = 8
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
        usleep(30_000)
    }
    usleep(600_000)

    // End the simulated drag with a real release. The controller defers
    // neighbour resizes until the click lifts (`mouseLifted`, wired to a
    // global left-mouse-up monitor), so nothing moves under a held
    // button: without a release the splitter advances and the windows
    // stay exactly where they were. The press is posted too, so the app
    // sees a real click gesture rather than a bare up event.
    if let f = actualFrame(t) {
        let c = CGPoint(x: f.midX, y: f.midY)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left))
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left))
        usleep(700_000)
    }

    // mirror splitter updates from the final frame
    guard let fin = actualFrame(t) else { return }
    func clamp(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat { min(max(v, r.lowerBound), r.upperBound) }
    switch (slot, edge) {
    case ("TL", "right"), ("BL", "right"), ("LH", "right"):
        col = clamp((fin.maxX - vf.minX) / vf.width, 0.15...0.85)
    case ("TR", "left"), ("BR", "left"), ("RH", "left"):
        col = clamp((fin.minX - vf.minX) / vf.width, 0.15...0.85)
    case ("TL", "bottom"), ("BL", "top"), ("TR", "bottom"), ("BR", "top"):
        let appkitY = primaryTop - (edge == "top" ? fin.minY : fin.maxY)
        let value = clamp((appkitY - vf.minY) / vf.height, 0.2...0.8)
        if slot == "TR" || slot == "BR" { rowR = value } else { rowL = value }
    // Sixths rows: one divider per third, so dragging a left sixth's
    // bottom edge must not move the middle or right thirds' divider.
    case ("sixthTopLeft", "bottom"), ("sixthBottomLeft", "top"):
        let appkitY = primaryTop - (edge == "top" ? fin.minY : fin.maxY)
        sixthsRowL = clamp((appkitY - vf.minY) / vf.height, 0.2...0.8)
    case ("sixthTopMiddle", "bottom"), ("sixthBottomMiddle", "top"):
        let appkitY = primaryTop - (edge == "top" ? fin.minY : fin.maxY)
        sixthsRowM = clamp((appkitY - vf.minY) / vf.height, 0.2...0.8)
    case ("sixthTopRight", "bottom"), ("sixthBottomRight", "top"):
        let appkitY = primaryTop - (edge == "top" ? fin.minY : fin.maxY)
        sixthsRowR = clamp((appkitY - vf.minY) / vf.height, 0.2...0.8)
    // Sixths columns. A two-thirds window drags its outer edge and keeps
    // the hidden inner divider at the midpoint of the resulting span,
    // which is how the app couples the two fractions.
    case ("sixthTopLeft", "right"), ("sixthBottomLeft", "right"), ("sixthLeft", "right"):
        sixthsL = clamp((fin.maxX - vf.minX) / vf.width, sixthsColumnClamp)
    case ("sixthTopRight", "left"), ("sixthBottomRight", "left"), ("sixthRight", "left"):
        sixthsR = clamp((fin.minX - vf.minX) / vf.width, sixthsColumnClamp)
    case ("sixthsLeftTwoThirds", "right"):
        sixthsR = clamp((fin.maxX - vf.minX) / vf.width, sixthsColumnClamp)
        sixthsL = sixthsR / 2
    case ("sixthsRightTwoThirds", "left"):
        sixthsL = clamp((fin.minX - vf.minX) / vf.width, sixthsColumnClamp)
        sixthsR = (sixthsL + 1) / 2
    default:
        break // screen edges: no splitter
    }
}

func simulateMove(_ t: String, by: CGSize) {
    guard let f = actualFrame(t), let el = hostWindows().first(where: { $0.title == t })?.el else { return }
    setRawFrame(el, f.offsetBy(dx: by.width, dy: by.height))
    usleep(600_000)
}

// MARK: verification

func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.maxX - b.maxX) <= tol
        && abs(a.minY - b.minY) <= tol && abs(a.maxY - b.maxY) <= tol
}

func verify(_ label: String, except excluded: Set<String> = []) {
    var ok = true
    let wins = hostWindows()
    func frameOf(_ t: String) -> CGRect? { wins.first(where: { $0.title == t })?.frame }
    for (t, slot) in tiled.sorted(by: { $0.key < $1.key }) where !excluded.contains(t) {
        guard let act = frameOf(t) else { ok = false; print("  FAIL \(label): \(t) missing"); continue }
        let exp = gridRect(slot)
        if !close(act, exp) {
            ok = false
            print("  FAIL \(label): \(t) [\(slot)] exp=\(exp) act=\(act)")
        }
    }
    for (t, pf) in preTile where tiled[t] == nil {
        guard frameOf(t) != nil else { continue }
        if let act = frameOf(t), !close(act, pf) {
            ok = false
            print("  FAIL \(label): \(t) (floating) exp=\(pf) act=\(act)")
        }
    }
    if ok { pass += 1; print("PASS \(label)") } else { fail += 1; print(">>>> FAILED: \(label)") }
}

// MARK: setup

for w in hostWindows() {
    switch w.title {
    case "HOSTA": setRawFrame(w.el, axRect(CGRect(x: 300, y: 600, width: 600, height: 350)))
    case "HOSTB": setRawFrame(w.el, axRect(CGRect(x: 350, y: 150, width: 600, height: 300)))
    case "HOSTC": setRawFrame(w.el, axRect(CGRect(x: 1000, y: 300, width: 500, height: 300)))
    case "HOSTD": setRawFrame(w.el, axRect(CGRect(x: 1050, y: 100, width: 400, height: 250)))
    default: break
    }
}
usleep(400_000)

// A fresh canvas starts in Sixths. Switch it explicitly to Quarters for
// the quarters family below; a slot key never switches a layout.
focus("HOSTA")
switchLayout()

// MARK: S1 - tile four quarters

doTile("HOSTA", "TL"); doTile("HOSTB", "BL"); doTile("HOSTC", "TR"); doTile("HOSTD", "BR")
verify("S1 tile four quarters")

// MARK: S1b - a sixths-only key is inert on a quarters canvas

// ⌥⇧I names Top Middle in Sixths, which Quarters has no slot for. The
// press must change neither the layout nor the occupancy: a switch would
// untile every window, and a stray placement would move one.
focus("HOSTA")
hotkey("TM")
usleep(900_000)
verify("S1b sixths-only key changed neither layout nor occupancy")

// MARK: S1c - the explicit switch untiles everyone; one undo restores all

// The switch is the newest chapter, so one undo must put back both the
// four quarter windows and the quarters layout. `preTile` holds each
// window's setup frame, captured when S1 first tiled it; after the switch
// the empty `tiled` map makes `verify` assert exactly those frames.
let quartersBefore = tiled
switchLayout()
tiled = [:]
verify("S1c switch untiled all four windows to their pre-tile frames")
pressUndo()
tiled = quartersBefore
verify("S1d undo restored the four quarter windows and the layout")

// If the undo restored Quarters, a sixths-only key is inert again. If it
// left Sixths, the key would tile and move the window off its quarter.
let aAfterUndo = actualFrame("HOSTA")
focus("HOSTA")
hotkey("TM")
usleep(900_000)
if let aAfterUndo, let aNow = actualFrame("HOSTA"), close(aNow, aAfterUndo) {
    pass += 1; print("PASS S1e undo restored Quarters: the sixths-only key is inert")
} else {
    fail += 1; print(">>>> FAILED S1e undo did not restore Quarters")
}

// MARK: S2 - column drag via BL right edge

dragEdge("HOSTB", "right", 100)
verify("S2 column split dragged +100 via BL.right")

// MARK: S3 - row drag via TL bottom edge

dragEdge("HOSTA", "bottom", -80)
verify("S3 row split dragged -80 via TL.bottom")

// MARK: S4 - column drag via TR left edge

dragEdge("HOSTC", "left", -50)
verify("S4 column split dragged -50 via TR.left")

// MARK: S5 - corner drag on BR (two edges at once)

dragEdge("HOSTD", "left", 40)
dragEdge("HOSTD", "top", 30)
verify("S5 BR left+top edges (corner-ish) drags")

// MARK: S6 - clamping

dragEdge("HOSTB", "right", -1500)
verify("S6a column clamped at 0.15", except: ["HOSTB"])
dragEdge("HOSTB", "right", 700)
verify("S6b column recovered to \(col)")

// MARK: S7 - screen edges must be inert

let colSaved = col, rowLSaved = rowL, rowRSaved = rowR
dragEdge("HOSTA", "left", 40)
dragEdge("HOSTB", "bottom", -40)
// Both windows were mutated off-grid; cycle them through an overlapping
// slot (evicting, never swapping) so each is placed back onto the grid.
// Self-tile is a no-op, so a direct re-press would leave them off-grid.
doTile("HOSTA", "LH") // evicts B; A placed into the left half
doTile("HOSTB", "BL") // evicts A; B placed into bottom left
doTile("HOSTA", "TL") // disjoint: A placed back into top left
// The re-assert is what makes this check real: the saved splitters imply
// these rects, so a screen-edge drag that moved a splitter would place
// the frames somewhere else (the mirrors stayed at their saved values).
if col == colSaved, rowL == rowLSaved, rowR == rowRSaved,
    let aFrame = actualFrame("HOSTA"), close(aFrame, gridRect("TL")),
    let bFrame = actualFrame("HOSTB"), close(bFrame, gridRect("BL"))
{
    pass += 1; print("PASS S7 screen-edge drags did not move splitters")
} else {
    fail += 1; print(">>>> FAILED S7: splitters moved on screen-edge drag")
}

// MARK: S8 - half over two quads evicts both

doTile("HOSTA", "LH")
verify("S8 LH over TL+BL: A in left half, B evicted")

// MARK: S9 - quad over occupied quad evicts

doTile("HOSTB", "BR")
verify("S9 B tiled BR, D evicted")

// MARK: S10 - same-tile re-press is a no-op

doTile("HOSTA", "LH") // already in LH: no-op, stays tiled
verify("S10a A still tiled LH after same-tile re-press")
doTile("HOSTA", "TL") // overlapping move: vacates LH, A lands TL
verify("S10b A moved LH -> TL")
doTile("HOSTA", "LH") // back into the resized left half
verify("S10c A retiled into resized left half")

// MARK: S11 - moving a tiled window is inert (v1), grid intact

simulateMove("HOSTA", by: CGSize(width: 60, height: 40))
// The title-bar move must not read as a splitter drag: the mirrors for
// the row/column fractions stay put, and the re-assert (any resize
// re-normalizes the grid) must put A exactly back on its tile. Comparing
// the app's frame to the rect the current splitters imply can fail; the
// old mirror-to-itself comparison could not.
dragEdge("HOSTC", "left", 30)
if let aFrame = actualFrame("HOSTA"), close(aFrame, gridRect("TL")) {
    pass += 1; print("PASS S11a title-bar move did not move splitters; A snapped back")
} else {
    fail += 1; print(">>>> FAILED S11a")
}
verify("S11b layout re-asserted: A snapped back onto grid")

// MARK: S12 - window close prunes cleanly

closeWindow("HOSTD")
usleep(600_000)
if actualFrame("HOSTD") == nil {
    pass += 1; print("PASS S12a HOSTD closed")
} else {
    fail += 1; print(">>>> FAILED S12a: HOSTD still alive")
}
doTile("HOSTC", "TR") // no-op re-press; still runs prune via hotkey path
verify("S12b state healthy after close + hotkey")

// MARK: S13 - retile cycle across slots

doTile("HOSTA", "TL"); doTile("HOSTB", "BL"); doTile("HOSTC", "TR")
verify("S13 retiled TL+BL+TR with current splitters")

// MARK: S14 - half over two occupied quads: double eviction

doTile("HOSTC", "LH") // TL(A) + BL(B) both occupied -> both evicted
verify("S14a C tiled LH; A and B both evicted (double eviction)")
doTile("HOSTA", "TL") // LH overlaps TL -> evicts C
verify("S14b A retiled TL; C evicted")
doTile("HOSTB", "BL"); doTile("HOSTC", "TR")
verify("S14c full grid restored")

// MARK: S15 - stress loop

for i in 1...3 {
    dragEdge("HOSTB", "right", 60)
    dragEdge("HOSTA", "bottom", -40)
    doTile("HOSTC", "TR") // no-op re-press: layout untouched
    verify("S15 iteration \(i)")
}

// MARK: S16 - swap: a lone blocker takes the vacated tile

// HOSTD was closed in S12a and never comes back, so the board holds A, B,
// and C. Clearing first makes the arrangement explicit rather than a
// leftover of S15, and the evictions also assert that each window returns
// to its pre-tile frame.
evict("HOSTA"); evict("HOSTB"); evict("HOSTC")
verify("S16a board cleared: A, B, C each back at their pre-tile frames")
doTile("HOSTA", "TL"); doTile("HOSTB", "BL")
verify("S16b A in TL, B in BL")

// A is tiled, exactly one window blocks BL, and the tile A vacates (TL)
// is disjoint from BL, so this swaps: nobody is untiled and B takes the
// vacated TL. A second blocker, an untiled requester, or a vacated tile
// overlapping the target would evict instead (S14a, S17c, S18b).
doTile("HOSTA", "BL")
verify("S16c swap: A in BL, B in TL, nobody evicted")

// MARK: S17 - re-house: a lone evictee stays tiled

evict("HOSTA"); evict("HOSTB"); evict("HOSTC")
doTile("HOSTA", "TL"); doTile("HOSTB", "BR")
verify("S17a A in TL, B in BR")

// C taking the left half overlaps only A (B sits bottom-right): A is the
// lone evictee, and the cells nobody occupies afterwards are exactly TR,
// so A re-tiles into TR instead of untangling.
doTile("HOSTC", "LH")
verify("S17b re-house: C in LH, A moved to TR, B untouched")

// MARK: S18 - undo restores a double eviction

evict("HOSTA"); evict("HOSTB"); evict("HOSTC")
doTile("HOSTA", "TL"); doTile("HOSTB", "BL")
verify("S18a A in TL, B in BL")

// The left half overlaps both A (TL) and B (BL): two evictees, so no
// swap (one blocker required) and no re-house (one evictee required).
// This is the newest undo chapter, so one ⌃⌥⇧⌘Z returns all of it: the
// evicted windows go back to their slots and the requester to its
// pre-tile frame.
doTile("HOSTC", "LH")
verify("S18b C in LH, A and B both evicted")
pressUndo()
usleep(1_500_000)
tiled["HOSTC"] = nil
tiled["HOSTA"] = "TL"
tiled["HOSTB"] = "BL"
verify("S18c undo returned A and B to their slots and C to its pre-tile frame")

// MARK: S19 - sixths: the explicit switch, the geometry, and per-third rows

// The explicit ⌥⇧\ switch changes the layout; a slot press never does. The
// board is cleared first so nothing is untiled by the switch and each
// placement's frame is the only thing under test.
evict("HOSTA"); evict("HOSTB"); evict("HOSTC")
verify("S19a board cleared before the layout switch")
switchLayout() // quarters -> sixths, explicitly
doTileSixths("HOSTA", "TL", "sixthTopLeft")
doTileSixths("HOSTB", "TM", "sixthTopMiddle")
doTileSixths("HOSTC", "TR", "sixthTopRight")
verify("S19b switched to sixths: three top sixths at equal thirds")

// One row divider per third: dragging the left sixth's bottom edge moves
// only the left third's divider, so the middle and right sixths keep
// their height. The app's own frames are the check: the mirror rects a
// drag cannot reach would pass no matter what the drag did.
let midBefore = actualFrame("HOSTB"), rightBefore = actualFrame("HOSTC")
dragEdge("HOSTA", "bottom", -60)
verify("S19c left sixth resized, middle and right sixths unmoved")
if let midBefore, let rightBefore,
    let midAfter = actualFrame("HOSTB"), let rightAfter = actualFrame("HOSTC"),
    close(midAfter, midBefore), close(rightAfter, rightBefore)
{
    pass += 1; print("PASS S19d per-third row independence: other thirds held")
} else {
    fail += 1; print(">>>> FAILED S19d: a sixths row drag moved another third")
}

// MARK: S20 - two-thirds keeps its hidden divider centered

evict("HOSTA"); evict("HOSTB"); evict("HOSTC")
doTileSixths("HOSTA", "L2", "sixthsLeftTwoThirds")
doTileSixths("HOSTB", "R", "sixthRight")
verify("S20a left two-thirds beside the right third")

// Dragging the two-thirds' outer edge moves the visible divider and
// re-centers the hidden one inside it, so the right third follows.
dragEdge("HOSTA", "right", 80)
verify("S20b two-thirds resized, right third followed")

// The hidden divider is only observable once a window sits on it: the
// middle third's rect starts where the hidden divider was left.
evict("HOSTA")
doTileSixths("HOSTB", "M", "sixthMiddle")
verify("S20c middle third lands on the re-centered hidden divider")

print("==============================")
print("PASS \(pass)  FAIL \(fail)")
exit(fail == 0 ? 0 : 1)
