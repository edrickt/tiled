import AppKit

// Measures the tile gap as it actually lands on screen.
//
// It reads window bounds from CGWindowListCopyWindowInfo, which needs no
// Accessibility permission (only AX frame reads and synthetic hotkeys
// do), so it runs unattended from any shell. Bounds are already in the
// same top-left-origin point space as the AX position the window manager
// writes, so measured gaps compare directly with the engine's targets.
//
// Usage: swift tools/repro/gap-probe.swift [Owner ...]
//        defaults to Firefox Terminal
//
// What to look for: with the default 5pt gap, two adjacent tiled windows
// show a 5pt gap between them and each screen edge shows 2.5pt. A window
// whose frame does not match the engine's target makes its neighbouring
// gap larger or smaller than 5.

let owners = Array(CommandLine.arguments.dropFirst())
let wanted = owners.isEmpty ? ["Firefox", "Terminal"] : owners

// The gap the running app is configured with.
func configuredGap() -> Double {
    guard let tiled = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == "Tiled" || $0.bundleIdentifier == "dev.tiled.app"
    }), let id = tiled.bundleIdentifier else { return 5 }
    let defaults = UserDefaults(suiteName: id)
    return (defaults?.object(forKey: "tileGap") as? Double) ?? 5
}

// The visible frame in top-left-origin global coords, matching
// CGWindowBounds (and the AX space the engine writes).
func visibleFrameTopLeft() -> CGRect? {
    guard let primary = NSScreen.screens.first else { return nil }
    let v = primary.visibleFrame
    let top = primary.frame.maxY
    return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
}

struct Win {
    var owner: String
    var title: String
    var frame: CGRect // top-left origin
}

func onScreenWindows() -> [Win] {
    let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let owner = w[kCGWindowOwnerName as String] as? String, wanted.contains(owner),
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let width = b["Width"] as? Double, let height = b["Height"] as? Double,
              width > 40, height > 40
        else { return nil }
        return Win(owner: owner, title: w[kCGWindowName as String] as? String ?? "",
                   frame: CGRect(x: x, y: y, width: width, height: height))
    }
}

let gap = configuredGap()
let windows = onScreenWindows()

print("configured gap = \(gap)pt")
if let v = visibleFrameTopLeft() {
    print("visible frame (top-left) = x \(v.minX)..\(v.maxX)  y \(v.minY)..\(v.maxY)")
}
print("")

for w in windows {
    print("\(w.owner) \"\(w.title)\"")
    print("  frame x \(w.frame.minX)..\(w.frame.maxX)  y \(w.frame.minY)..\(w.frame.maxY)")
    if let v = visibleFrameTopLeft() {
        let left = w.frame.minX - v.minX
        let right = v.maxX - w.frame.maxX
        let top = w.frame.minY - v.minY
        let bottom = v.maxY - w.frame.maxY
        print(String(format: "  screen-edge gaps: left %.1f  right %.1f  top %.1f  bottom %.1f",
                     left, right, top, bottom))
    }
}
print("")

// Pairwise gaps between every measured window: the smallest separation
// along each axis. An adjacent tiled pair should read exactly `gap`.
if windows.count >= 2 {
    print("pairwise gaps (shared edges):")
    for i in 0..<windows.count {
        for j in (i + 1)..<windows.count {
            let a = windows[i].frame, b = windows[j].frame
            let horizOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY) > 1
            let vertOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX) > 1
            if horizOverlap {
                let sep = max(b.minX, a.minX) - min(b.maxX, a.maxX)
                if sep >= 0, sep < 60 {
                    print(String(format: "  %@ <-> %@  horizontal gap %.1f",
                                 windows[i].owner, windows[j].owner, sep))
                }
            }
            if vertOverlap {
                let sep = max(b.minY, a.minY) - min(b.maxY, a.maxY)
                if sep >= 0, sep < 60 {
                    print(String(format: "  %@ <-> %@  vertical gap %.1f",
                                 windows[i].owner, windows[j].owner, sep))
                }
            }
        }
    }
}
