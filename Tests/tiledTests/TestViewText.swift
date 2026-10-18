import AppKit

/// Recursively collects every text field's rendered string in a view.
/// Shared by the Settings UI tests so copy assertions read one helper.
func textLabels(in view: NSView) -> [String] {
    let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
    return own + view.subviews.flatMap { textLabels(in: $0) }
}
