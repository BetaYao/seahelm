import AppKit

protocol DividerDelegate: AnyObject {
    func dividerDidBeginDrag(_ splitNodeId: String)
    func dividerDidMove(_ splitNodeId: String, newRatio: CGFloat)
    func dividerDidEndDrag(_ splitNodeId: String)
    func dividerDidDoubleClick(_ splitNodeId: String)
}

/// Draggable divider between split panes: 1pt layout/visual seam inside a wide
/// hit strip (same idea as `ChromeDividerView`), so the grip is easy to catch.
/// Host defers Ghostty PTY `set_size` for the drag session (SIGWINCH tolerance).
class DividerView: NSView {
    let splitNodeId: String
    let axis: SplitAxis
    weak var delegate: DividerDelegate?

    /// Gap reserved between panes in the split geometry.
    static let thickness: CGFloat = 1
    /// Invisible drag tolerance centered on the seam.
    static let hitThickness: CGFloat = 16
    private static let activeVisualThickness: CGFloat = 2

    private let lineLayer = CALayer()
    private let hoverFillLayer = CALayer()
    private var isDragging = false
    private var isHovered = false
    private var dragStartPoint: CGPoint = .zero
    private var dragStartRatio: CGFloat = 0
    var parentSplitSize: CGFloat = 0
    var currentRatio: CGFloat = 0.5

    init(splitNodeId: String, axis: SplitAxis) {
        self.splitNodeId = splitNodeId
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hoverFillLayer.opacity = 0
        layer?.addSublayer(hoverFillLayer)
        layer?.addSublayer(lineLayer)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        hoverFillLayer.frame = bounds
        layoutLine()
    }

    private func layoutLine() {
        let visual = (isHovered || isDragging) ? Self.activeVisualThickness : Self.thickness
        switch axis {
        case .horizontal:
            let x = (bounds.width - visual) / 2
            lineLayer.frame = CGRect(x: x, y: 0, width: visual, height: bounds.height)
        case .vertical:
            let y = (bounds.height - visual) / 2
            lineLayer.frame = CGRect(x: 0, y: y, width: bounds.width, height: visual)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        hoverFillLayer.backgroundColor = resolvedCGColor(
            NSColor.controlAccentColor.withAlphaComponent(0.10)
        )
        applyLineColor()
    }

    private func applyLineColor() {
        if isHovered || isDragging {
            lineLayer.backgroundColor = resolvedCGColor(NSColor.controlAccentColor)
        } else {
            lineLayer.backgroundColor = resolvedCGColor(NSColor.separatorColor)
        }
        layoutLine()
        hoverFillLayer.opacity = (isHovered || isDragging) ? 1 : 0
    }

    // MARK: - Hit testing / cursor

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
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
        resizeCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyLineColor()
        resizeCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        isHovered = false
        applyLineColor()
    }

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    // MARK: - Drag

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            delegate?.dividerDidDoubleClick(splitNodeId)
            return
        }
        isDragging = true
        isHovered = true
        applyLineColor()
        dragStartPoint = convert(event.locationInWindow, from: nil)
        dragStartRatio = currentRatio
        resizeCursor.set()
        delegate?.dividerDidBeginDrag(splitNodeId)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, parentSplitSize > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta: CGFloat
        if axis == .horizontal {
            delta = point.x - dragStartPoint.x
        } else {
            // Match historical sign in the flipped split container.
            delta = -(point.y - dragStartPoint.y)
        }
        let ratioDelta = delta / parentSplitSize
        let newRatio = min(max(dragStartRatio + ratioDelta, 0.1), 0.9)
        delegate?.dividerDidMove(splitNodeId, newRatio: newRatio)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let stillInside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHovered = stillInside
        applyLineColor()
        delegate?.dividerDidEndDrag(splitNodeId)
    }
}
