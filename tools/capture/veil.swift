import AppKit

// Hides every app except the capture cast, and restores exactly those it
// hid. A README asset should show the demo windows, not the machine's
// owner; this keeps unrelated windows (and the previous scene's clutter)
// out of the frame without touching the apps themselves.
//
//   swift tools/capture/veil.swift hide    [state.json]
//   swift tools/capture/veil.swift restore [state.json]
//
// `NSRunningApplication.isHidden` settles asynchronously — it can still
// read false right after a successful hide — so nothing here branches on
// it: the state file is the list of apps we asked to hide, and restore
// unhides every one of them. Unhiding an app that is already visible is a
// no-op, and an app the user hid by hand is never in the list.

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "hide"
let statePath = arguments.count > 1 ? arguments[1] : "build/capture/veiled.json"

/// Apps that belong in the capture: the demo cast and Tiled itself.
let cast: Set<String> = ["Tiled", "tiled", "demo-host", "host"]

func key(_ app: NSRunningApplication) -> String {
    app.bundleIdentifier ?? app.localizedName ?? "?"
}

func candidates() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { app in
        guard app.activationPolicy == .regular, !app.isTerminated else { return false }
        return !cast.contains(app.localizedName ?? "")
    }
}

func readState() -> [String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
        let list = try? JSONSerialization.jsonObject(with: data) as? [String]
    else { return [] }
    return list
}

func writeState(_ list: [String]) {
    try? FileManager.default.createDirectory(
        atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])
    try? data?.write(to: URL(fileURLWithPath: statePath))
}

switch mode {
case "hide":
    let visible = candidates().filter { !$0.isHidden }
    for app in visible { _ = app.hide() }
    // Keep earlier entries: a second capture run must not forget who hid
    // the apps that are already hidden when it starts.
    let hid = Array(Set(readState() + visible.map(key))).sorted()
    writeState(hid)
    print("hid \(visible.count) app(s); \(hid.count) on the restore list")
case "restore":
    let hid = readState()
    var shown = 0
    for app in candidates() where hid.contains(key(app)) {
        if app.unhide() { shown += 1 }
    }
    writeState([])
    print("restored \(shown) app(s)")
default:
    FileHandle.standardError.write("usage: veil.swift hide|restore [state.json]\n".data(using: .utf8)!)
    exit(2)
}
