import AppKit

/// Vertical chrome divider: 1px visual line inside a wider drag hit target.
final class ChromeDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?

    private let lineLayer = CALayer()
    private var lastDragX: CGFloat = 0
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("chrome.divider")

        lineLayer.backgroundColor = NSColor.separatorColor.cgColor
        layer?.addSublayer(lineLayer)
    }

    override func layout() {
        super.layout()
        let visual = ChromeLayoutMetrics.dividerVisualWidth
        let x = (bounds.width - visual) / 2
        lineLayer.frame = CGRect(x: x, y: 0, width: visual, height: bounds.height)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        lastDragX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let deltaX = x - lastDragX
        lastDragX = x
        if deltaX != 0 {
            onDrag?(deltaX)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}
