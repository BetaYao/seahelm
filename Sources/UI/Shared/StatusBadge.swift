import AppKit

/// Small status indicator dot with color
class StatusBadge: NSView {
    var status: AgentStatus = .unknown {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = min(bounds.width, bounds.height)
        let rect = NSRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        status.color.setFill()
        path.fill()
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: Theme.statusBadgeSize, height: Theme.statusBadgeSize)
    }
}
