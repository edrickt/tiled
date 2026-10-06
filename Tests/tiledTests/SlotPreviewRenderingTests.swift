import AppKit
import XCTest

@testable import tiled

final class SlotPreviewRenderingTests: XCTestCase {
    private func findQuartersPreview(in view: NSView) -> SlotPreviewView? {
        if let preview = view as? SlotPreviewView,
           preview.accessibilityLabel() == "Preview: Top Left covers the top-left quarter" {
            return preview
        }
        return view.subviews.lazy.compactMap { self.findQuartersPreview(in: $0) }.first
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.setFrameSize(NSSize(width: 160, height: 100))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSColor.clear.setFill()
            view.bounds.fill()
            view.draw(view.bounds)
        }
        return bitmap
    }

    func testWelcomeQuartersShowsTwoColumnsWithoutInternalRefinementGaps() throws {
        let suite = "SlotPreviewRenderingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = WelcomeTab(hotkeyStore: HotkeyStore(defaults: defaults))
            .build(size: NSSize(width: 440, height: 480))
        let preview = try XCTUnwrap(findQuartersPreview(in: view))
        let bitmap = try render(preview)

        // Both rows must have solid quarters, not gaps at the old 4-column boundaries.
        for y in [25, 75] {
            XCTAssertEqual(bitmap.colorAt(x: 40, y: y), bitmap.colorAt(x: 20, y: y))
            XCTAssertEqual(bitmap.colorAt(x: 120, y: y), bitmap.colorAt(x: 100, y: y))
            XCTAssertEqual(bitmap.colorAt(x: 80, y: y)?.alphaComponent, 0,
                           "The actual two-column boundary remains separated.")
        }
        XCTAssertNotEqual(bitmap.colorAt(x: 20, y: 25), bitmap.colorAt(x: 100, y: 25),
                          "Only the top-left quarter is highlighted.")
        XCTAssertEqual(bitmap.colorAt(x: 20, y: 75), bitmap.colorAt(x: 100, y: 75),
                       "Neither bottom quarter is highlighted.")
    }
}
