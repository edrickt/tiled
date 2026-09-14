import AppKit

// Demo windows for the README's captured assets. Not part of Tiled: this
// host exists so the tiling GIFs show real windows with recognisable
// content instead of six identical grey rectangles. Everything is drawn
// with AppKit primitives, so it has no assets to ship and renders the
// same on every machine.
//
// Usage: demo-host          (six scattered windows, one per mock app)

// MARK: - Palette

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

enum Ink {
    // Editor
    static let editorBG = NSColor(hex: 0x12141A)
    static let editorTab = NSColor(hex: 0x171A22)
    static let editorTabActive = NSColor(hex: 0x1E2330)
    static let editorGutter = NSColor(hex: 0x0E1016)
    static let editorLineNo = NSColor(hex: 0x3A4252)
    static let editorText = NSColor(hex: 0xD7DCEA)
    static let keyword = NSColor(hex: 0xC792EA)
    static let str = NSColor(hex: 0xC3E88D)
    static let type = NSColor(hex: 0x82AAFF)
    static let comment = NSColor(hex: 0x5C6675)
    static let number = NSColor(hex: 0xF78C6C)
    // Terminal
    static let termBG = NSColor(hex: 0x0E1014)
    static let termChrome = NSColor(hex: 0x161A21)
    static let termDim = NSColor(hex: 0x6C7689)
    static let green = NSColor(hex: 0x7BD88F)
    static let amber = NSColor(hex: 0xE8C07D)
    static let cyan = NSColor(hex: 0x76D0E0)
    // Notes
    static let paper = NSColor(hex: 0xFBFAF7)
    static let paperRule = NSColor(hex: 0xE7E2D8)
    static let heading = NSColor(hex: 0x1C1F26)
    static let body = NSColor(hex: 0x5A6273)
    static let accent = NSColor(hex: 0xC2410C)
    // Files
    static let filesBG = NSColor(hex: 0xFFFFFF)
    static let sidebar = NSColor(hex: 0xF2F3F6)
    static let sidebarSel = NSColor(hex: 0xE2E8F4)
    static let hairline = NSColor(hex: 0xE4E7EC)
    static let fileText = NSColor(hex: 0x333A47)
    static let fileDim = NSColor(hex: 0x8B93A3)
    static let blue = NSColor(hex: 0x3B6FE0)
    // Browser
    static let page = NSColor(hex: 0xFFFFFF)
    static let browserChrome = NSColor(hex: 0xF2F3F5)
    static let addressBar = NSColor(hex: 0xE6E8EC)
    static let violet = NSColor(hex: 0x6E56CF)
    static let card = NSColor(hex: 0xF1F2F6)
    // Music
    static let musicBG = NSColor(hex: 0x14121C)
    static let musicCard = NSColor(hex: 0x1E1B2A)
    static let lilac = NSColor(hex: 0xB39DFF)
    static let pink = NSColor(hex: 0xF07BA8)
}

// MARK: - Drawing helpers

let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
let monoSmall = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
let ui = NSFont.systemFont(ofSize: 12)
let uiSmall = NSFont.systemFont(ofSize: 10.5)
let uiSemibold = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

extension NSAttributedString {
    convenience init(_ text: String, _ font: NSFont, _ color: NSColor) {
        self.init(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}

func label(_ text: String, _ font: NSFont, _ color: NSColor, at point: NSPoint) {
    NSAttributedString(text, font, color).draw(at: point)
}

/// Draws text clipped to `width`, wrapping to as many lines as fit in `height`.
@discardableResult
func wrappedText(
    _ text: String, _ font: NSFont, _ color: NSColor, in rect: NSRect, lineHeight: CGFloat
) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = lineHeight / font.pointSize
    style.lineBreakMode = .byWordWrapping
    let attributed = NSAttributedString(
        string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    return rect.height
}

func fillRect(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    if radius > 0 {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    } else {
        rect.fill()
    }
}

func symbol(_ name: String, _ color: NSColor, size: CGFloat = 11) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    image?.isTemplate = true
    return image
}

// MARK: - Panes

class Pane: NSView {
    override var isFlipped: Bool { true }
}

/// A code editor with a file tab, gutter and syntax-coloured Swift.
final class CodePane: Pane {
    private let lines: [(Int, [(String, NSColor)])] = [
        (1, [("/// ", Ink.comment), ("A display\u{2019}s one Mission Control Space", Ink.comment)]),
        (2, [("struct ", Ink.keyword), ("CanvasState", Ink.type), (" {", Ink.editorText)]),
        (3, [("    var ", Ink.keyword), ("layout", Ink.editorText), (": ", Ink.editorText), ("Layout", Ink.type), (" = .sixths", Ink.editorText)]),
        (4, [("    var ", Ink.keyword), ("occupant", Ink.editorText), (": [", Ink.editorText), ("Slot", Ink.type), (": ", Ink.editorText), ("WindowID", Ink.type), ("] = [:]", Ink.editorText)]),
        (5, [("    var ", Ink.keyword), ("undo", Ink.editorText), (": [", Ink.editorText), ("Chapter", Ink.type), ("] = []", Ink.editorText)]),
        (7, [("    func ", Ink.keyword), ("plan", Ink.editorText), ("(", Ink.editorText), ("tile", Ink.editorText), (": ", Ink.editorText), ("Slot", Ink.type), (") -> ", Ink.editorText), ("Decision", Ink.type), (" {", Ink.editorText)]),
        (8, [("        if ", Ink.keyword), ("occupant[tile] == requester { ", Ink.editorText), ("return ", Ink.keyword), (".noop }", Ink.editorText)]),
        (9, [("        let ", Ink.keyword), ("blocked", Ink.editorText), (" = overlap(with: tile)", Ink.editorText)]),
        (10, [("        // one blocker with a disjoint home swaps; more evicts", Ink.comment)]),
        (11, [("        if ", Ink.keyword), ("blocked.count == ", Ink.editorText), ("1", Ink.number), (", let ", Ink.keyword), ("home", Ink.editorText), (" = vacated {", Ink.editorText)]),
        (12, [("            return ", Ink.keyword), (".swap(blocked[", Ink.editorText), ("0", Ink.number), ("], into: home)", Ink.editorText)]),
        (13, [("        }", Ink.editorText)]),
        (14, [("        return ", Ink.keyword), (".tile(evicting: blocked, reflow: reflow(blocked))", Ink.editorText)]),
        (15, [("    }", Ink.editorText)]),
        (17, [("    /// ", Ink.comment), ("Rightmost candidate wins when both flanks grow.", Ink.comment)]),
        (18, [("    func ", Ink.keyword), ("reflow", Ink.editorText), ("(", Ink.editorText), ("_ freed", Ink.editorText), (": [", Ink.editorText), ("TileCell", Ink.type), ("]) -> ", Ink.editorText), ("Reflow?", Ink.type), (" {", Ink.editorText)]),
        (19, [("        survivors", Ink.editorText), (".last", Ink.editorText), (" { merge(", Ink.editorText), ("$0", Ink.editorText), (".cells, freed) }", Ink.editorText)]),
        (20, [("    }", Ink.editorText)]),
        (21, [("}", Ink.editorText)]),
    ]

    override func draw(_ dirtyRect: NSRect) {
        fillRect(bounds, Ink.editorBG)
        let tabHeight: CGFloat = 30
        fillRect(NSRect(x: 0, y: 0, width: bounds.width, height: tabHeight), Ink.editorTab)
        let tabRect = NSRect(x: 8, y: 5, width: min(190, bounds.width - 16), height: tabHeight - 10)
        fillRect(tabRect, Ink.editorTabActive, radius: 5)
        label("Layout.swift", monoSmall, Ink.type, at: NSPoint(x: tabRect.minX + 10, y: tabRect.minY + 5))
        label("PlanExecutor.swift", monoSmall, Ink.comment, at: NSPoint(x: tabRect.maxX + 14, y: tabRect.minY + 5))

        let gutter: CGFloat = 46
        fillRect(NSRect(x: 0, y: tabHeight, width: gutter, height: bounds.height - tabHeight), Ink.editorGutter)
        let lineHeight: CGFloat = 17
        var y = tabHeight + 10
        for (number, segments) in lines {
            if y + lineHeight > bounds.height + lineHeight { break }
            let numberText = NSAttributedString("\(number)", mono, Ink.editorLineNo)
            let size = numberText.size()
            numberText.draw(at: NSPoint(x: gutter - 12 - size.width, y: y))
            var x = gutter + 12
            for (text, color) in segments {
                let attributed = NSAttributedString(text, mono, color)
                attributed.draw(at: NSPoint(x: x, y: y))
                x += attributed.size().width
            }
            y += lineHeight
        }
    }
}

/// A terminal mid-build.
final class TerminalPane: Pane {
    private let lines: [(String, NSColor)] = [
        ("\u{276F} swift test", Ink.termDim),
        ("Building for testing...", Ink.termDim),
        ("[42/42] Linking tiledPackageTests", Ink.termDim),
        ("", Ink.termDim),
        ("Test Suite 'All tests' passed", Ink.green),
        ("\t Executed 550 tests, 0 failures in 1.786s", Ink.editorText),
        ("", Ink.termDim),
        ("\u{276F} ./scripts/run-repro.sh", Ink.termDim),
        ("PASS  quarters / top-left tiling", Ink.green),
        ("PASS  quarters / eviction restores the victim", Ink.green),
        ("PASS  sixths / layout switch untiles the canvas", Ink.green),
        ("PASS  resize / per-column row independence", Ink.green),
        ("", Ink.termDim),
        ("\u{276F} python3 tools/mutation/mutate.py", Ink.termDim),
        ("43 mutants, 0 survivors \u{2014} the suite noticed every bug", Ink.amber),
        ("\u{276F} \u{2588}", Ink.editorText),
    ]

    override func draw(_ dirtyRect: NSRect) {
        fillRect(bounds, Ink.termBG)
        fillRect(NSRect(x: 0, y: 0, width: bounds.width, height: 26), Ink.termChrome)
        label("tiled \u{2014} zsh \u{2014} 80\u{00D7}24", monoSmall, Ink.termDim, at: NSPoint(x: 12, y: 7))
        let lineHeight: CGFloat = 16
        var y: CGFloat = 38
        for (text, color) in lines {
            if y + lineHeight > bounds.height + lineHeight { break }
            label(text, mono, color, at: NSPoint(x: 14, y: y))
            y += lineHeight
        }
    }
}

/// A short ruling document, warm paper stock.
final class NotesPane: Pane {
    override func draw(_ dirtyRect: NSRect) {
        fillRect(bounds, Ink.paper)
        let inset: CGFloat = 28
        let width = bounds.width - inset * 2
        guard width > 60 else { return }
        label("Tiling rules", NSFont.systemFont(ofSize: 17, weight: .semibold), Ink.heading, at: NSPoint(x: inset, y: 30))
        fillRect(NSRect(x: inset, y: 58, width: 42, height: 3), Ink.accent, radius: 1.5)

        var y: CGFloat = 78
        let bullets = [
            "One window per tile. Tiling into an occupied slot evicts the occupant.",
            "A lone blocker swaps instead: it moves into the tile the requester vacated.",
            "Freed cells merge with one neighbour \u{2014} rightmost wins ties.",
            "Expand covers the layout; the window keeps its slot underneath.",
        ]
        for bullet in bullets {
            if y > bounds.height - 20 { break }
            label("\u{2022}", ui, Ink.accent, at: NSPoint(x: inset, y: y))
            let height = min(46, bounds.height - y - 6)
            let rect = NSRect(x: inset + 16, y: y, width: width - 16, height: height)
            wrappedText(bullet, ui, Ink.body, in: rect, lineHeight: 16)
            y += 44
        }
        if y < bounds.height - 44 {
            let box = NSRect(x: inset, y: y + 4, width: width, height: 34)
            fillRect(box, NSColor(hex: 0xF3EFE6), radius: 6)
            label("\u{2325}\u{21E7}\u{2318}U", mono, Ink.accent, at: NSPoint(x: box.minX + 12, y: box.minY + 10))
            label("Tile the focused window top left", ui, Ink.body, at: NSPoint(x: box.minX + 92, y: box.minY + 10))
        }
    }
}

/// A file browser: sidebar plus a source listing.
final class FilesPane: Pane {
    private let groups = ["Sources", "Tests", "tools", "docs"]
    private let files: [(String, String)] = [
        ("Layout.swift", "22 KB"), ("TilingController.swift", "61 KB"),
        ("DragTracker.swift", "21 KB"), ("PlanExecutor.swift", "22 KB"),
        ("LiveWindowGateway.swift", "38 KB"), ("HotkeyService.swift", "11 KB"),
        ("MenuModel.swift", "12 KB"), ("StatusIcon.swift", "3 KB"),
    ]

    override func draw(_ dirtyRect: NSRect) {
        fillRect(bounds, Ink.filesBG)
        let sidebarWidth: CGFloat = min(132, bounds.width * 0.34)
        fillRect(NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height), Ink.sidebar)
        var y: CGFloat = 16
        for (index, group) in groups.enumerated() {
            if y > bounds.height - 20 { break }
            let row = NSRect(x: 6, y: y - 3, width: sidebarWidth - 12, height: 22)
            if index == 0 { fillRect(row, Ink.sidebarSel, radius: 5) }
            if let icon = symbol("folder", index == 0 ? Ink.blue : Ink.fileDim) {
                icon.draw(in: NSRect(x: 14, y: y, width: 13, height: 13))
            }
            label(group, ui, index == 0 ? Ink.heading : Ink.fileText, at: NSPoint(x: 34, y: y))
            y += 26
        }
        let listX = sidebarWidth + 18
        var rowY: CGFloat = 20
        for (name, size) in files {
            if rowY > bounds.height - 16 { break }
            if let icon = symbol("chevron.right", Ink.fileDim, size: 8) {
                icon.draw(in: NSRect(x: listX - 12, y: rowY + 2, width: 8, height: 8))
            }
            if let icon = symbol("swift", Ink.blue) {
                icon.draw(in: NSRect(x: listX, y: rowY - 1, width: 13, height: 13))
            }
            label(name, ui, Ink.fileText, at: NSPoint(x: listX + 20, y: rowY))
            let sizeText = NSAttributedString(size, uiSmall, Ink.fileDim)
            sizeText.draw(at: NSPoint(x: bounds.width - 18 - sizeText.size().width, y: rowY + 1))
            fillRect(NSRect(x: listX, y: rowY + 24, width: bounds.width - listX - 10, height: 1), Ink.hairline)
            rowY += 30
        }
    }
}

/// A browser window on the project's own page.
final class BrowserPane: Pane {
    override func draw(_ dirtyRect: NSRect) {
        fillRect(bounds, Ink.page)
        let chrome: CGFloat = 34
        fillRect(NSRect(x: 0, y: 0, width: bounds.width, height: chrome), Ink.browserChrome)
        let tab = NSRect(x: 12, y: 6, width: min(150, bounds.width * 0.35), height: chrome - 12)
        fillRect(tab, Ink.page, radius: 6)
        label("Tiled \u{2014} README", uiSmall, Ink.fileText, at: NSPoint(x: tab.minX + 10, y: tab.minY + 5))
        let address = NSRect(x: tab.maxX + 10, y: 6, width: max(40, bounds.width - tab.maxX - 30), height: chrome - 12)
        fillRect(address, Ink.addressBar, radius: chrome / 2 - 6)
        if let icon = symbol("lock.fill", Ink.fileDim, size: 9) {
            icon.draw(in: NSRect(x: address.minX + 9, y: address.minY + 7, width: 9, height: 9))
        }
        label("github.com/edrickt/tiled", uiSmall, Ink.fileText, at: NSPoint(x: address.minX + 24, y: address.minY + 5))

        var y = chrome + 26
        label("Tiled", NSFont.systemFont(ofSize: 21, weight: .bold), Ink.heading, at: NSPoint(x: 24, y: y))
        y += 30
        label("A native macOS window manager.", ui, Ink.body, at: NSPoint(x: 24, y: y))
        y += 26
        let cards: [(String, String, NSColor)] = [
            ("Quarters", "2\u{00D7}2 grid plus halves", Ink.violet),
            ("Sixths", "3\u{00D7}2 grid plus thirds", Ink.blue),
            ("Live resize", "shared edges follow", Ink.accent),
            ("Per-Space", "every desktop its own", Ink.green),
        ]
        let gap: CGFloat = 12
        let cardWidth = (bounds.width - 24 * 2 - gap) / 2
        for (index, card) in cards.enumerated() {
            let column = CGFloat(index % 2), row = CGFloat(index / 2)
            let rect = NSRect(
                x: 24 + column * (cardWidth + gap), y: y + row * 56,
                width: cardWidth, height: 46)
            guard rect.maxY < bounds.height - 10, cardWidth > 60 else { break }
            fillRect(rect, Ink.card, radius: 8)
            fillRect(NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height), card.2, radius: 1.5)
            label(card.0, uiSemibold, Ink.heading, at: NSPoint(x: rect.minX + 14, y: rect.minY + 8))
            label(card.1, uiSmall, Ink.fileDim, at: NSPoint(x: rect.minX + 14, y: rect.minY + 26))
        }
    }
}

/// A music player: album art, track, waveform.
final class MusicPane: Pane {
    private let bars: [CGFloat] = [
        0.2, 0.45, 0.8, 0.6, 0.95, 0.5, 0.3, 0.7, 0.9, 0.4, 0.25, 0.65,
        0.85, 0.55, 0.35, 0.75, 0.5, 0.2, 0.6, 0.9, 0.45, 0.3, 0.7, 0.4,
    ]

    override func draw(_ dirtyRect: NSRect) {
        fillRect(bounds, Ink.musicBG)
        let artSize = min(bounds.width - 48, bounds.height * 0.42, 150)
        guard artSize > 30 else { return }
        let art = NSRect(x: (bounds.width - artSize) / 2, y: 28, width: artSize, height: artSize)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: art, xRadius: artSize * 0.08, yRadius: artSize * 0.08).addClip()
        NSGradient(starting: Ink.violet, ending: Ink.pink)?.draw(in: art, angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        // A smaller inner square keeps it readable as album art at tile size.
        let inner = art.insetBy(dx: artSize * 0.22, dy: artSize * 0.22)
        fillRect(inner, NSColor(hex: 0x14121C, alpha: 0.55), radius: artSize * 0.1)
        label("TILED", NSFont.systemFont(ofSize: artSize * 0.13, weight: .heavy), NSColor.white.withAlphaComponent(0.92),
             at: NSPoint(x: inner.minX + inner.width * 0.16, y: inner.midY - artSize * 0.07))

        let titleY = art.maxY + 18
        if titleY < bounds.height - 40 {
            label("Tiling Suite", uiSemibold, NSColor.white, at: NSPoint(x: 24, y: titleY))
            label("The Splitters", uiSmall, Ink.lilac, at: NSPoint(x: 24, y: titleY + 18))
        }
        let waveY = min(bounds.height - 24, titleY + 46)
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 5
        var x: CGFloat = 24
        for value in bars {
            if x + barWidth > bounds.width - 20 { break }
            let height = value * 22
            fillRect(NSRect(x: x, y: waveY + (22 - height), width: barWidth, height: height), Ink.lilac, radius: 1.5)
            x += barWidth + spacing
        }
    }
}

// MARK: - Host

NSWindow.allowsAutomaticWindowTabbing = false
let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class DemoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

func makeWindow(_ title: String, _ frame: NSRect, _ pane: NSView) -> NSWindow {
    let window = DemoWindow(
        contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = title
    window.isRestorable = false
    window.contentView = pane
    window.makeKeyAndOrderFront(nil)
    return window
}

/// Scattered start: a normal desktop before anything is tiled. Coordinates
/// are fractions of the visible frame, so the layout adapts to any display.
func place(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1680, height: 1050)
    return NSRect(
        x: screen.minX + screen.width * x, y: screen.minY + screen.height * y,
        width: screen.width * width, height: screen.height * height)
}

let known: Set<String> = ["editor", "terminal", "notes", "files", "browser", "music"]

/// Which mock app this process is: the first argument, or — so each window
/// can be its own process (and thus its own name in Tiled's window list) —
/// the executable's own name (build/cast/Editor, build/cast/Terminal, …).
let wants: Set<String> = {
    let names = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    if !names.isEmpty { return Set(names) }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent.lowercased()
    return known.contains(executable) ? [executable] : []
}()
func wanted(_ name: String) -> Bool { wants.isEmpty || wants.contains(name) }

if wanted("editor") {
    _ = makeWindow("Layout.swift \u{2014} tiled", place(0.05, 0.60, 0.44, 0.36), CodePane())
}
if wanted("terminal") {
    _ = makeWindow("tiled \u{2014} zsh", place(0.55, 0.62, 0.41, 0.34), TerminalPane())
}
if wanted("notes") {
    _ = makeWindow("Tiling rules", place(0.12, 0.10, 0.36, 0.36), NotesPane())
}
if wanted("files") {
    _ = makeWindow("Sources \u{2014} Files", place(0.55, 0.12, 0.38, 0.36), FilesPane())
}
if wanted("browser") {
    _ = makeWindow("Tiled \u{2014} README", place(0.24, 0.03, 0.46, 0.40), BrowserPane())
}
if wanted("music") {
    _ = makeWindow("Music", place(0.02, 0.05, 0.24, 0.44), MusicPane())
}

app.run()
