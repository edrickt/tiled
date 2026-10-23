import AppKit
import XCTest

@testable import tiled

final class ShortcutsGuidanceTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func testRecordingGuidanceIsVisibleBeforeTheRecordersAtDefaultAndMinimumSizes() throws {
        let suite = "ShortcutsGuidanceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for size in [NSSize(width: 440, height: 480), NSSize(width: 400, height: 268)] {
            let tab = ShortcutsTab(hotkeyStore: HotkeyStore(defaults: defaults), defaults: defaults)
            let view = tab.build(size: size, window: nil)
            view.layoutSubtreeIfNeeded()
            let views = descendants(of: view)
            let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
            let hint = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
                $0.stringValue.contains("Click a shortcut")
            })
            let first = try XCTUnwrap(tab.firstRecorder)
            let hintRect = hint.convert(hint.bounds, to: scroll.documentView)
            let recorderRect = first.convert(first.bounds, to: scroll.documentView)

            XCTAssertLessThanOrEqual(hintRect.maxY, recorderRect.minY,
                                     "Instructions must precede the first recorder, not follow all 17.")
            XCTAssertTrue(scroll.documentVisibleRect.contains(hintRect),
                          "Instructions must be readable without scrolling at \(size).")
            XCTAssertTrue(hint.stringValue.contains("Esc"))
            XCTAssertTrue(hint.stringValue.contains("⌫"))
            XCTAssertEqual(views.compactMap { $0 as? RecorderButton }.count, 17)
        }
    }
}
