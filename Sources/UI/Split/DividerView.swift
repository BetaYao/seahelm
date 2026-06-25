import AppKit

protocol DividerDelegate: AnyObject {
    func dividerDidMove(_ splitNodeId: String, newRatio: CGFloat)
    func dividerDidDoubleClick(_ splitNodeId: String)
}

/// Draggable divider between split panes.
class DividerView: NSView {
    let splitNodeId: String
    let axis: SplitAxis
    weak var delegate: DividerDelegate?

    static let thickness: CGFloat = 4

    private var isDragging = false
    private var dragStartPoint: CGPoint = .zero
    private var dragStartRatio: CGFloat = 0
    var parentSplitSize: CGFloat = 0
    var currentRatio: CGFloat = 0.5

    init(splitNodeId: String, axis: SplitAxis) {
        self.splitNodeId = splitNodeId
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            delegate?.dividerDidDoubleClick(splitNodeId)
            return
        }
        isDragging = true
        dragStartPoint = convert(event.locationInWindow, from: nil)
        dragStartRatio = currentRatio
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, parentSplitSize > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta: CGFloat
        if axis == .horizontal {
            delta = point.x - dragStartPoint.x
        } else {
            delta = -(point.y - dragStartPoint.y)
        }
        let ratioDelta = delta / parentSplitSize
        let newRatio = min(max(dragStartRatio + ratioDelta, 0.1), 0.9)
        delegate?.dividerDidMove(splitNodeId, newRatio: newRatio)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
