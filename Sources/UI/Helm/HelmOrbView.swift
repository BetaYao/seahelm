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
    /// Rotating conic-gradient sweep wedge (the radar beam), clipped to a disc.
    private let sweepLayer = CAGradientLayer()
    /// Two faint concentric rings inside the beam.
    private let ring1 = CAShapeLayer()
    private let ring2 = CAShapeLayer()
    /// Bright center pip (drawn above the sweep).
    private let pipLayer = CAShapeLayer()
    private var badgeCount = 0
    /// Sweep only animates while at least one agent is running/waiting; otherwise
    /// the radar sits still (rings + center pip, no beam).
    private var isActive = false

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

        // Radar beam: a conic gradient that's transparent for most of the circle
        // and ramps up to the radar colour over a trailing wedge (matches the
        // prototype `conic-gradient(transparent 0–248°, radar 318°, transparent 360°)`).
        sweepLayer.type = .conic
        sweepLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        sweepLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            Self.radar.cgColor,
            NSColor.clear.cgColor,
        ]
        sweepLayer.locations = [0.0, 0.689, 0.883, 1.0]
        sweepLayer.opacity = 0.5
        sweepLayer.isHidden = true  // static until an agent is running/waiting
        layer?.addSublayer(sweepLayer)

        // Concentric rings.
        for (ring, alpha) in [(ring1, CGFloat(0.22)), (ring2, CGFloat(0.16))] {
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = Self.radar.withAlphaComponent(alpha).cgColor
            ring.lineWidth = 1
            layer?.addSublayer(ring)
        }

        // Center pip on top of the sweep.
        pipLayer.fillColor = Self.radar.cgColor
        layer?.addSublayer(pipLayer)

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Sweep fills the disc (inset past the outer ring) and is clipped round.
        let sweepRect = bounds.insetBy(dx: 3, dy: 3)
        sweepLayer.frame = sweepRect
        sweepLayer.cornerRadius = sweepRect.width / 2
        sweepLayer.masksToBounds = true

        // Rings at increasing inset.
        ring1.path = ringPath(inset: 7)
        ring2.path = ringPath(inset: 13)
        ring1.frame = bounds
        ring2.frame = bounds

        // Center pip.
        let pipR: CGFloat = 3
        pipLayer.path = CGPath(ellipseIn: CGRect(x: bounds.midX - pipR, y: bounds.midY - pipR,
                                                 width: pipR * 2, height: pipR * 2), transform: nil)
        pipLayer.frame = bounds

        CATransaction.commit()
        startSweepIfNeeded()
    }

    private func ringPath(inset: CGFloat) -> CGPath {
        let r = bounds.insetBy(dx: inset, dy: inset)
        return CGPath(ellipseIn: r, transform: nil)
    }

    /// Drive the sweep on/off. Active = some agent running/waiting.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        sweepLayer.isHidden = !active
        if active {
            startSweepIfNeeded()
        } else {
            sweepLayer.removeAnimation(forKey: "spin")
        }
    }

    private func startSweepIfNeeded() {
        guard isActive else { sweepLayer.isHidden = true; return }
        guard sweepLayer.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -CGFloat.pi * 2
        spin.duration = 3.6
        spin.repeatCount = .infinity
        // anchorPoint is 0.5,0.5 by default → rotates about the sweep's own center.
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
        // Sweep wedge, rings, and center pip are layers (see setup/layout).
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override var acceptsFirstResponder: Bool { false }
}
