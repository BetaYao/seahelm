import AppKit

extension NSView {
    func descendantViews() -> [NSView] {
        subviews + subviews.flatMap { $0.descendantViews() }
    }
}
