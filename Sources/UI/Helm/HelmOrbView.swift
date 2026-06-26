import AppKit

/// Bottom-center "First Mate" radar orb — the single entry point to the Helm
/// cockpit. Click toggles the floating command center. A pending-order badge
/// pulses in the top-right corner.
///
/// Styling is the Bare-TUI palette inlined locally (THEME.A in the prototype):
/// flat dark fill, hairline accent ring, no glow. When the global theme layer
/// (WP-1) lands these literals move into the semantic tokens.
final class HelmOrbView: NSView {

    // Bare-TUI palette (prototype THEME.A)
    private static let fill   = NSColor(srgbRed: 0x0e/255, green: 0x2d/255, blue: 0x37/255, alpha: 1)
    private static let ring   = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 0.55)
    private static let radar  = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)
    private static let orange = NSColor(srgbRed: 0xff/255, green: 0x8a/255, blue: 0x3d/255, alpha: 1)
    private static let statusBg = NSColor(srgbRed: 0x0a/255, green: 0x26/255, blue: 0x30/255, alpha: 1)

    var onToggle: (() -> Void)?

    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let sweepLayer = CAShapeLayer()
    private var badgeCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 44).isActive = true

        // Base disc + ring drawn in draw(_:). Rotating sweep arc is a layer.
        sweepLayer.fillColor = NSColor.clear.cgColor
        sweepLayer.strokeColor = Self.radar.withAlphaComponent(0.5).cgColor
        sweepLayer.lineWidth = 1.5
        sweepLayer.lineCap = .round
        layer?.addSublayer(sweepLayer)

        // Pending badge (top-right)
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = Self.orange.cgColor
        badgeContainer.layer?.cornerRadius = 8.5
        badgeContainer.layer?.borderWidth = 2
        badgeContainer.layer?.borderColor = Self.statusBg.cgColor
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.isHidden = true
        addSubview(badgeContainer)

        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = NSColor(srgbRed: 0x1a/255, green: 0x10/255, blue: 0x08/255, alpha: 1)
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            badgeContainer.topAnchor.constraint(equalTo: topAnchor, constant: -3),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3),
            badgeContainer.heightAnchor.constraint(equalToConstant: 17),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 17),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 4),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
        ])

        toolTip = "First Mate"
    }

    override func layout() {
        super.layout()
        // Sweep arc sits just inside the ring.
        let inset: CGFloat = 5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: rect.width / 2,
                    startAngle: 0, endAngle: .pi * 0.55, clockwise: false)
        sweepLayer.path = path
        sweepLayer.frame = bounds
        startSweepIfNeeded()
    }

    private func startSweepIfNeeded() {
        guard sweepLayer.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -CGFloat.pi * 2
        spin.duration = 3.6
        spin.repeatCount = .infinity
        // Rotate about the layer center.
        sweepLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        sweepLayer.frame = bounds
        sweepLayer.add(spin, forKey: "spin")
    }

    func setBadge(_ count: Int) {
        badgeCount = count
        badgeContainer.isHidden = count <= 0
        badgeLabel.stringValue = count > 99 ? "99+" : "\(count)"
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let disc = NSBezierPath(ovalIn: rect)
        Self.fill.setFill()
        disc.fill()
        Self.ring.setStroke()
        disc.lineWidth = 1
        disc.stroke()

        // Center pip
        let pip = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6))
        Self.radar.setFill()
        pip.fill()
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override var acceptsFirstResponder: Bool { false }
}
