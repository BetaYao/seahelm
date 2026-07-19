import AppKit

/// Icon button that behaves reliably in window chrome headers: it takes the
/// very first click even when the window isn't key (no click-to-activate
/// swallowing the press) and never hands its area to window dragging.
final class ChromeIconButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
