import AppKit
import ApplicationServices

// Drives the demo host through one scripted scene and records it.
//
//   swift tools/capture/scene-driver.swift quarters --out /tmp/quarters.mov
//
// Assumes Tiled (dev build) and the demo cast (build/cast/*) are already
// running. Every step
// is a global hotkey, an AX focus, or a real mouse drag: exactly what a
// person does. The recorder is screencapture's own video mode, so nothing
// here needs extra tooling.

// MARK: - AX plumbing

func attr(_ el: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name, &value) == .success else { return nil }
    return value
}

struct Win {
    let el: AXUIElement
    let pid: pid_t
    let title: String
    let frame: CGRect
}

func windows(of pid: pid_t) -> [Win] {
    guard let raw = attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString),
        let list = raw as? [AXUIElement]
    else { return [] }
    return list.compactMap { el in
        guard let rect = elementFrame(el) else { return nil }
        let title = attr(el, kAXTitleAttribute as CFString) as? String ?? ""
        return Win(el: el, pid: pid, title: title, frame: rect)
    }
}

func elementFrame(_ el: AXUIElement) -> CGRect? {
    guard let position = attr(el, kAXPositionAttribute as CFString),
        let size = attr(el, kAXSizeAttribute as CFString)
    else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    return CGRect(origin: point, size: dimensions)
}

/// A window that just appeared (or was just re-shown) can still be moving
/// to its autosaved frame while AX already answers. Wait for two identical
/// reads before believing a frame — a crop taken mid-move is off by the
/// distance it still had to travel.
func stableFrame(_ el: AXUIElement) -> CGRect? {
    var previous = elementFrame(el)
    for _ in 0..<10 {
        usleep(250_000)
        guard let next = elementFrame(el) else { return previous }
        if next == previous { return next }
        previous = next
    }
    return previous
}

func app(named name: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.localizedName == name || $0.executableURL?.lastPathComponent == name
    }
}

func tiledPID() -> pid_t {
    guard let tiled = app(named: "tiled") else { fatalError("tiled is not running") }
    return tiled.processIdentifier
}

/// The demo windows run as one process per mock app (build/cast/Editor,
/// build/cast/Terminal, …) so Tiled's menu lists them like real apps.
func castApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { app in
        guard let url = app.executableURL else { return false }
        return url.deletingLastPathComponent().lastPathComponent == "cast"
    }
}

func allWindows() -> [Win] {
    castApps().flatMap { windows(of: $0.processIdentifier) }
}

@discardableResult
func focus(_ title: String) -> Win? {
    guard let target = allWindows().first(where: { $0.title.hasPrefix(title) }) else {
        FileHandle.standardError.write("no window titled \(title)\n".data(using: .utf8)!)
        return nil
    }
    NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(target.el, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(target.el, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(target.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    // A real click on the title bar is what actually makes the window the
    // frontmost app's focused window; programmatic activation from a
    // script is not always honoured. It also parks the pointer where the
    // GIF's cursor reads as "this window is next".
    let point = CGPoint(x: target.frame.midX, y: target.frame.minY + 12)
    moveMouse(to: point)
    click(at: point)
    usleep(280_000)
    return target
}

func click(at point: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
}

// MARK: - Input

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "tab": 48, "space": 49, "return": 36, "delete": 51, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
    usleep(25_000)
}

func moveMouse(to point: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
}

/// Modifier keys, pressed for real rather than only advertised in the
/// letter key's flags. Posting just the flags leaves the session's
/// modifier state stuck: later synthetic clicks then arrive as ⌥⌘-clicks
/// (which macOS answers with "hide all other apps"), and every window but
/// the clicked one vanishes from the recording.
let modifierKeys: [(String, CGEventFlags, CGKeyCode)] = [
    ("cmd", .maskCommand, 55),
    ("shift", .maskShift, 56),
    ("alt", .maskAlternate, 58),
    ("ctrl", .maskControl, 59),
]

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
    event?.flags = flags
    post(event)
}

func key(_ combo: String) {
    let parts = combo.split(separator: "+").map(String.init)
    guard let name = parts.last, let code = keyCodes[name.lowercased()] else {
        fatalError("unknown key in \(combo)")
    }
    var modifiers: [(CGEventFlags, CGKeyCode)] = []
    for part in parts.dropLast() {
        guard let match = modifierKeys.first(where: { $0.0 == part.lowercased() }) else {
            fatalError("unknown modifier \(part)")
        }
        modifiers.append((match.1, match.2))
    }
    var live: CGEventFlags = []
    for (flag, keyCode) in modifiers {
        live.insert(flag)
        postKey(keyCode, down: true, flags: live)
    }
    postKey(code, down: true, flags: live)
    postKey(code, down: false, flags: live)
    for (flag, keyCode) in modifiers.reversed() {
        live.remove(flag)
        postKey(keyCode, down: false, flags: live)
    }
}

func drag(from start: CGPoint, to end: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left))
    usleep(120_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left))
    let steps = 26
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
        usleep(18_000)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
}

// MARK: - Tiled's status menu

func statusItem() -> AXUIElement? {
    let element = AXUIElementCreateApplication(tiledPID())
    guard let extras = attr(element, kAXExtrasMenuBarAttribute as CFString) else { return nil }
    return (attr(extras as! AXUIElement, kAXChildrenAttribute as CFString) as? [AXUIElement])?.first
}

func menuItem(_ title: String) -> AXUIElement? {
    guard let item = statusItem() else { return nil }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    usleep(350_000)
    func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 4 else { return nil }
        if let children = attr(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                if let role = attr(child, kAXRoleAttribute as CFString) as? String,
                    role == (kAXMenuItemRole as String),
                    let value = attr(child, kAXTitleAttribute as CFString) as? String,
                    value.hasPrefix(title)
                {
                    return child
                }
                if let found = walk(child, depth: depth + 1) { return found }
            }
        }
        return nil
    }
    return walk(item, depth: 0)
}

func pressMenu(_ title: String) {
    guard let item = menuItem(title) else {
        FileHandle.standardError.write("menu item \(title) not found\n".data(using: .utf8)!)
        return
    }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    usleep(400_000)
}

// MARK: - Settings window and menu frames

func tiledWindows() -> [Win] { windows(of: tiledPID()) }

func settingsWindow() -> Win? {
    tiledWindows().first { $0.title == "Tiled" }
}

func closeSettingsIfOpen() {
    guard let window = settingsWindow() else { return }
    if let button = attr(window.el, kAXCloseButtonAttribute as CFString) {
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        usleep(300_000)
    }
}

/// Presses a radio button (a tab) inside the Settings window.
func pressTab(_ title: String) {
    guard let window = settingsWindow() else { return }
    func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 6 else { return nil }
        if let children = attr(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                if let value = attr(child, kAXTitleAttribute as CFString) as? String, value == title,
                    let role = attr(child, kAXRoleAttribute as CFString) as? String,
                    role == (kAXRadioButtonRole as String)
                {
                    return child
                }
                if let found = walk(child, depth: depth + 1) { return found }
            }
        }
        return nil
    }
    guard let tab = walk(window.el, depth: 0) else {
        FileHandle.standardError.write("tab \(title) not found\n".data(using: .utf8)!)
        return
    }
    AXUIElementPerformAction(tab, kAXPressAction as CFString)
    usleep(400_000)
}

/// AX frames of the surfaces a screenshot wants to crop to, in screen
/// points (top-left origin, what `screencapture -R` takes).
func emitCropFrames() {
    if let window = tiledWindows().first(where: { $0.title == "Tiled" }),
        let frame = stableFrame(window.el)
    {
        print(String(format: "crop settings %.0f %.0f %.0f %.0f",
            frame.minX, frame.minY, frame.width, frame.height))
    }
    if let item = statusItem(),
        let menu = (attr(item, kAXChildrenAttribute as CFString) as? [AXUIElement])?.first,
        let frame = stableFrame(menu), frame.width > 40, frame.height > 40
    {
        print(String(format: "crop menu %.0f %.0f %.0f %.0f",
            frame.minX, frame.minY, frame.width, frame.height))
    }
}

enum Step {
    case focus(String)
    case key(String)
    case wait(Double)
    case drag(from: CGPoint, to: CGPoint)
    /// Drag a tiled window's edge: the shared splitter moves, the neighbour
    /// follows. `delta` is applied to the edge's midpoint.
    case dragEdge(window: String, edge: Edge, delta: CGSize)
    case menu(String)
    case statusItem
    /// Press a tab in Tiled's Settings window by title (Welcome/Shortcuts).
    case tab(String)
    case closeSettings
}

enum Edge { case right, bottom }

struct Scene {
    let steps: [Step]
    /// Seconds of quiet before the first step, and after the last one.
    var lead: Double = 0.9
    var tail: Double = 1.0
}

// Hotkeys, spelled out so a reader can match them to the README tables.
let quarterTL = "alt+shift+cmd+u", quarterTR = "alt+shift+cmd+o"
let quarterBL = "alt+shift+cmd+m", quarterBR = "alt+shift+cmd+."
let leftHalf = "alt+shift+cmd+j", rightHalf = "alt+shift+cmd+l"
let sixthTL = "alt+shift+u", sixthTM = "alt+shift+i", sixthTR = "alt+shift+o"
let sixthBL = "alt+shift+m", sixthBM = "alt+shift+,", sixthBR = "alt+shift+."
let leftThird = "alt+shift+j", middleThird = "alt+shift+k", rightThird = "alt+shift+l"
let expandKey = "alt+shift+return", evictKey = "alt+shift+delete"

func scene(named name: String) -> Scene {
    switch name {
    case "quarters":
        // Four scattered windows land in the 2x2 grid, one hotkey each.
        return Scene(steps: [
            .focus("Layout.swift"), .key(quarterTL), .wait(0.35),
            .focus("tiled — zsh"), .key(quarterTR), .wait(0.35),
            .focus("Tiling rules"), .key(quarterBL), .wait(0.35),
            .focus("Sources — Files"), .key(quarterBR), .wait(0.6),
        ])
    case "halves":
        // Two windows split the screen in half, then the left one becomes
        // quarters: the same canvas, no eviction because nothing overlaps.
        return Scene(steps: [
            .focus("Layout.swift"), .key(leftHalf), .wait(0.4),
            .focus("Tiled — README"), .key(rightHalf), .wait(0.7),
        ])
    case "sixths":
        // The full 3x2: six windows, six hotkeys, no eviction.
        return Scene(steps: [
            .focus("Layout.swift"), .key(sixthTL), .wait(0.3),
            .focus("tiled — zsh"), .key(sixthTM), .wait(0.3),
            .focus("Tiled — README"), .key(sixthTR), .wait(0.3),
            .focus("Tiling rules"), .key(sixthBL), .wait(0.3),
            .focus("Music"), .key(sixthBM), .wait(0.3),
            .focus("Sources — Files"), .key(sixthBR), .wait(0.7),
        ])
    case "thirds":
        // Three columns, then two-thirds: the hidden divider stays centred.
        return Scene(steps: [
            .focus("Layout.swift"), .key(leftThird), .wait(0.35),
            .focus("tiled — zsh"), .key(middleThird), .wait(0.35),
            .focus("Tiling rules"), .key(rightThird), .wait(0.6),
        ])
    case "resize":
        // Drag the divider between two halves; the neighbour follows.
        return Scene(steps: [
            .focus("Layout.swift"), .key(leftHalf), .wait(0.3),
            .focus("tiled — zsh"), .key(rightHalf), .wait(0.8),
            .dragEdge(window: "Layout.swift", edge: .right, delta: CGSize(width: -150, height: 0)),
            .wait(0.8),
            .dragEdge(window: "Layout.swift", edge: .right, delta: CGSize(width: 300, height: 0)),
            .wait(0.7),
        ], lead: 1.0, tail: 0.8)
    case "expand":
        // Cover the layout, then return to the slot underneath.
        return Scene(steps: [
            .focus("Layout.swift"), .key(quarterTL), .wait(0.25),
            .focus("tiled — zsh"), .key(quarterTR), .wait(0.25),
            .focus("Tiling rules"), .key(quarterBL), .wait(0.25),
            .focus("Sources — Files"), .key(quarterBR), .wait(0.7),
            .focus("Tiling rules"), .key(expandKey), .wait(1.0),
            .key(expandKey), .wait(0.8),
        ], lead: 0.9, tail: 0.8)
    case "evict":
        // Bottom-left leaves; the top-left sixth grows into the left third.
        return Scene(steps: [
            .focus("Layout.swift"), .key(sixthTL), .wait(0.3),
            .focus("Tiling rules"), .key(sixthBL), .wait(0.3),
            .focus("tiled — zsh"), .key(rightThird), .wait(0.8),
            .focus("Tiling rules"), .key(evictKey), .wait(1.0),
        ], lead: 0.9, tail: 0.9)
    case "undo":
        // A layout switch untiles the canvas; one undo brings it all back.
        return Scene(steps: [
            .focus("Layout.swift"), .key(quarterTL), .wait(0.25),
            .focus("tiled — zsh"), .key(quarterTR), .wait(0.25),
            .focus("Tiling rules"), .key(quarterBL), .wait(0.25),
            .focus("Sources — Files"), .key(quarterBR), .wait(0.8),
            .focus("Tiled — README"), .key(sixthTL), .wait(2.0),
            .key("ctrl+alt+shift+cmd+z"), .wait(1.2),
        ], lead: 0.9, tail: 0.9)
    case "menu":
        // Quarters first: a menu with real state (window rows, undo, untile)
        // teaches more than an empty one. Then it stays open for the shot.
        return Scene(steps: [
            .focus("Layout.swift"), .key(quarterTL), .wait(0.2),
            .focus("tiled — zsh"), .key(quarterTR), .wait(0.2),
            .focus("Tiling rules"), .key(quarterBL), .wait(0.2),
            .focus("Sources — Files"), .key(quarterBR), .wait(0.5),
            .statusItem, .wait(0.1),
        ], lead: 0.4, tail: 1.6)
    case "guide":
        // The first-run Welcome tab, reopened from the menu.
        return Scene(steps: [.menu("Tiled Guide"), .wait(0.4)], lead: 0.5, tail: 2.0)
    case "shortcuts":
        // Settings, Shortcuts tab.
        return Scene(steps: [.focus("Layout.swift"), .key(quarterTL), .wait(0.4),
            .menu("Settings…"), .tab("Shortcuts"), .wait(0.4)], lead: 0.5, tail: 2.0)
    default:
        fatalError("unknown scene \(name)")
    }
}

// MARK: - Recording

let args = Array(CommandLine.arguments.dropFirst())
guard let sceneName = args.first else {
    FileHandle.standardError.write("usage: scene-driver <scene> [--out file.mov]\n".data(using: .utf8)!)
    exit(2)
}
let script = scene(named: sceneName)
var output: String? = nil
if let index = args.firstIndex(of: "--out"), index + 1 < args.count { output = args[index + 1] }

// The first-run Welcome tab opens Settings at launch; scenes that are not
// about Settings want the windows, not the guide, in frame.
if sceneName != "guide" && sceneName != "shortcuts" {
    closeSettingsIfOpen()
}

// Estimated wall time of the steps themselves (each step's own sleeps).
let stepTime: Double = script.steps.reduce(0) { total, step in
    switch step {
    case .focus: return total + 0.32
    case .key: return total + 0.10
    case .wait(let seconds): return total + seconds
    case .drag: return total + 0.75
    case .dragEdge: return total + 0.9
    case .menu: return total + 0.4
    case .statusItem: return total + 0.45
    case .tab: return total + 0.4
    case .closeSettings: return total + 0.3
    }
}
let sceneSeconds = stepTime
let total = script.lead + sceneSeconds + script.tail

var recorder: Process? = nil
if let output {
    try? FileManager.default.removeItem(atPath: output)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // Record the visible frame only: the menu bar and Dock are not what
    // the assets are about, and cropping at capture keeps the video small.
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
    let region = "0,\(Int(menuBar)),\(Int(screen.frame.width)),\(Int(screen.frame.height - menuBar))"
    process.arguments = [
        "-x", "-C", "-D", "1", "-R", region,
        "-V", String(Int(total.rounded(.up)) + 1), output,
    ]
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        FileHandle.standardError.write("cannot start screencapture: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    recorder = process
    print("recording \(Int(total.rounded(.up)) + 1)s to \(output)")
    usleep(UInt32(script.lead * 1_000_000))
}

for step in script.steps {
    switch step {
    case .focus(let title):
        focus(title)
    case .key(let combo):
        key(combo)
        usleep(100_000)
    case .wait(let seconds):
        usleep(UInt32(seconds * 1_000_000))
    case .drag(let from, let to):
        drag(from: from, to: to)
    case .dragEdge(let windowTitle, let edge, let delta):
        guard let target = allWindows().first(where: { $0.title.hasPrefix(windowTitle) })
        else { break }
        let start: CGPoint
        switch edge {
        case .right: start = CGPoint(x: target.frame.maxX - 3, y: target.frame.midY)
        case .bottom: start = CGPoint(x: target.frame.midX, y: target.frame.maxY - 3)
        }
        drag(from: start, to: CGPoint(x: start.x + delta.width, y: start.y + delta.height))
    case .menu(let title):
        pressMenu(title)
    case .statusItem:
        if let item = statusItem() { AXUIElementPerformAction(item, kAXPressAction as CFString) }
        usleep(450_000)
    case .tab(let title):
        pressTab(title)
    case .closeSettings:
        closeSettingsIfOpen()
    }
}

usleep(UInt32(script.tail * 1_000_000))
if let recorder, recorder.isRunning { recorder.waitUntilExit() }

// Final frames: the cheapest way to confirm a scene actually landed (a
// scene driven against a Tiled without Accessibility permission leaves
// the windows where they started).
for window in allWindows() {
    print(String(format: "final  %-24@ %.0f,%.0f %.0fx%.0f", window.title as NSString,
        window.frame.minX, window.frame.minY, window.frame.width, window.frame.height))
}

// Sidecar timeline: mov2gif trims the lead-in and tail with these.
if let output {
    let timeline = "start=\(script.lead)\nend=\(script.lead + sceneSeconds)\n"
    try? timeline.write(toFile: output + ".timeline", atomically: true, encoding: .utf8)
    print("timeline start=\(script.lead) end=\(script.lead + sceneSeconds)")
}

emitCropFrames()
