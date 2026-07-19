import AppKit

/// Vertical chrome divider: thin visual line inside a wide drag hit target,
/// with hover/drag accent highlight for easier targeting.
final class ChromeDividerView: NSView {
    /// Fired on each drag delta (points). Host should update layout only.
    var onDrag: ((CGFloat) -> Void)?
    /// Drag session lifecycle — host should defer PTY/SIGWINCH until end.
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let lineLayer = CALayer()
    private let hoverFillLayer = CALayer()
    private var lastDragX: CGFloat = 0
    private var isDragging = false
    private var isHovered = false

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
        setAccessibilityLabel("Resize sidebar")
        setAccessibilityRole(.splitter)

        hoverFillLayer.opacity = 0
        layer?.addSublayer(hoverFillLayer)
        layer?.addSublayer(lineLayer)
        refreshAppearance()
    }

    override func layout() {
        super.layout()
        hoverFillLayer.frame = bounds
        layoutLine()
    }

    private func layoutLine() {
        let visual = isHovered || isDragging
            ? ChromeLayoutMetrics.dividerActiveVisualWidth
            : ChromeLayoutMetrics.dividerVisualWidth
        let x = (bounds.width - visual) / 2
        lineLayer.frame = CGRect(x: x, y: 0, width: visual, height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        hoverFillLayer.backgroundColor = resolvedCGColor(
            SemanticColors.accent.withAlphaComponent(0.10)
        )
        applyLineColor()
    }

    private func applyLineColor() {
        if isHovered || isDragging {
            lineLayer.backgroundColor = resolvedCGColor(SemanticColors.accent)
        } else {
            lineLayer.backgroundColor = resolvedCGColor(NSColor.separatorColor)
        }
        layoutLine()
        hoverFillLayer.opacity = (isHovered || isDragging) ? 1 : 0
    }

    // MARK: - Hit testing / cursor

    /// Always claim points inside the hit strip so glass/terminal siblings can't steal them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyLineColor()
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        isHovered = false
        applyLineColor()
    }

    // MARK: - Drag

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        isHovered = true
        applyLineColor()
        lastDragX = event.locationInWindow.x
        NSCursor.resizeLeftRight.set()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let x = event.locationInWindow.x
        let deltaX = x - lastDragX
        lastDragX = x
        if deltaX != 0 {
            onDrag?(deltaX)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let stillInside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHovered = stillInside
        applyLineColor()
        onDragEnded?()
    }
}
