import AppKit
import CoreGraphics
import Foundation

// Reports the identities Tiled's canvas keys are built from: the
// CoreGraphics display number per NSScreen, and the window server's
// display-UUID -> current Space id64 table. Run before and after a
// sleep/wake cycle; a changed display number with the same UUID is the
// canvas-key churn hypothesis.

private typealias CGSDefaultConnectionFn = @convention(c) () -> Int32
private typealias CGSCopyManagedDisplaySpacesFn =
    @convention(c) (Int32) -> Unmanaged<CFArray>?

private func cgsSymbol<T>(_ name: String, as type: T.Type) -> T? {
    let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        ?? dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
}

print("== NSScreen identity (the canvas key's display half)")
for (index, screen) in NSScreen.screens.enumerated() {
    let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber)?.uint32Value ?? 0
    print("screen[\(index)] displayID=\(number) name=\(screen.localizedName)")
}

print("== Space table (uuid -> current space id64)")
if let connection = cgsSymbol("_CGSDefaultConnection", as: CGSDefaultConnectionFn.self)?(),
    let copySpaces = cgsSymbol(
        "CGSCopyManagedDisplaySpaces", as: CGSCopyManagedDisplaySpacesFn.self),
    let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
{
    for display in displays {
        let identifier = display["Display Identifier"] as? String ?? "?"
        let id64 = (display["Current Space"] as? [String: Any])?["id64"] ?? "?"
        print("display \(identifier) current-space-id64=\(id64)")
    }
} else {
    print("Space table unavailable")
}
