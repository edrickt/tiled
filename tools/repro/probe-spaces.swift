import CoreGraphics
import Foundation

// Reports the window server's Space table: one entry per display, with the
// Spaces each display owns and which one is showing.
//
// Why this exists: Tiled keys every canvas on (display, Space), so this
// table is the environment the live suites run in. Two checks need it.
//
//   * `suite.swift` grows per-Space scenarios only where a second Space
//     exists. With one Space, "move right a space" is a no-op, so those
//     scenarios cannot run at all and the per-canvas rules stay covered by
//     the unit suite plus `multi-display-checklist.md`.
//   * `multi-display-suite.swift` needs one Space per attached display.
//
// Read-only: it never switches anything. Run it before a live run whose
// results look surprising: a single Space or a single display explains
// most of them.
//
//     swift tools/repro/probe-spaces.swift

private typealias CGSDefaultConnectionFn = @convention(c) () -> Int32
private typealias CGSCopyManagedDisplaySpacesFn =
    @convention(c) (Int32) -> Unmanaged<CFArray>?

/// Same private symbols `LiveWindowGateway` resolves, at the same path:
/// SkyLight on every macOS that has Mission Control, CoreGraphics as the
/// fallback for a future OS that moves them.
private func cgsSymbol<T>(_ name: String, as type: T.Type) -> T? {
    let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        ?? dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
}

guard
    let connection = cgsSymbol("_CGSDefaultConnection", as: CGSDefaultConnectionFn.self)?(),
    let copySpaces = cgsSymbol("CGSCopyManagedDisplaySpaces", as: CGSCopyManagedDisplaySpacesFn.self),
    let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
else {
    print("The window server's Space table is unavailable on this macOS.")
    print("Tiled falls back to one canvas per display, which is still correct.")
    exit(0)
}

var totalSpaces = 0
for display in displays {
    let identifier = display["Display Identifier"] as? String ?? "?"
    let spaces = display["Spaces"] as? [[String: Any]] ?? []
    let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
    totalSpaces += spaces.count
    print("display \(identifier): \(spaces.count) space(s)")
    for space in spaces {
        let id = space["ManagedSpaceID"] as? Int ?? -1
        let type = space["type"] as? Int ?? -1
        let kind = type == 0 ? "desktop" : "fullscreen-or-other (type \(type))"
        print("  space \(id) · \(kind)\(id == current ? " · showing" : "")")
    }
}

print("---")
print("\(displays.count) display(s), \(totalSpaces) space(s) total")
if displays.count < 2 {
    print("multi-display suite: cannot run (needs two attached displays)")
}
if totalSpaces < 2 {
    print("per-Space live scenarios: cannot run (a Space switch needs a second Space)")
} else {
    print("per-Space live scenarios: available")
}
