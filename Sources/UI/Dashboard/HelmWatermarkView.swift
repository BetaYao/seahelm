import AppKit

/// The terminal side of an empty fleet: the Seahelm helm (the mark in
/// `site/favicon.svg`) drawn faintly as a dot matrix, centred in the slot.
///
/// The mark is sampled on a square grid in the favicon's 100×100 space — rim,
/// eight spokes, their knobs and the hub — and every grid point inside it gets
/// a dot. Dots fade towards the rim of the mark so it reads as a watermark,
/// not a picture. Purely decorative: no hit testing, no accessibility element.
final class HelmWatermarkView: NSView {
    /// Grid pitch in the mark's 100-unit space; ~52 dots across.
    private static let pitch: CGFloat = 1.9

    /// Grid points of the mark in 100-unit space, with a 0…1 weight
    /// (1 = the hub, falling off outwards). Computed once.
    private static let dots: [(CGPoint, CGFloat)] = {
        var result: [(CGPoint, CGFloat)] = []
        let c = CGPoint(x: 50, y: 50)
        var y: CGFloat = pitch / 2
        while y < 100 {
            var x: CGFloat = pitch / 2
            while x < 100 {
                let p = CGPoint(x: x, y: y)
                if contains(p) {
                    let r = hypot(p.x - c.x, p.y - c.y)
                    result.append((p, max(0.55, 1 - r / 80)))
                }
                x += pitch
            }
            y += pitch
        }
        return result
    }()

    /// Whether a point (100-unit space) falls on the helm.
    private static func contains(_ p: CGPoint) -> Bool {
        let dx = p.x - 50, dy = p.y - 50
        let r = hypot(dx, dy)
        // Hub: a ring with a boss in the middle, so it reads as a wheel's hub
        // rather than a blot.
        if r <= 6.5 || abs(r - 13) <= 2.6 { return true }
        // Rim: ring of radius 30, a little bolder than the favicon's stroke.
        if abs(r - 30) <= 2.8 { return true }
        // Spokes out to radius 36 (the favicon's line ends).
        if r <= 36 {
            for k in 0..<8 {
                let a = CGFloat(k) * .pi / 4
                // Distance from the point to the spoke's line through the centre.
                let d = abs(dx * sin(a) - dy * cos(a))
                let along = dx * cos(a) + dy * sin(a)
                if d <= 1.7, along >= 13 { return true }
            }
        }
        // Knobs at radius 37.
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4
            let kx = 50 + 37 * cos(a), ky = 50 + 37 * sin(a)
            if hypot(p.x - kx, p.y - ky) <= 4.4 { return true }
        }
        return false
    }

    /// The dots sit on the terminal slot, painted in the terminal's palette
    /// (`GhosttyBridge.terminalIsDark`, which `terminal_theme_mode` can pin
    /// apart from the app) — so the ink follows the terminal, not
    /// `effectiveAppearance`, or a pinned Latte would get white dots.
    private static var dotColor: NSColor {
        GhosttyBridge.terminalIsDark
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.07)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(paletteDidChange),
            name: .ghosttyColorSchemeDidChange, object: nil)
    }

    @objc private func paletteDidChange() { needsDisplay = true }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Half the shorter side, capped so a huge window does not get a
        // billboard; slightly above centre, where the eye rests.
        let side = min(min(bounds.width, bounds.height) * 0.5, 460)
        guard side > 40 else { return }
        let scale = side / 100
        let origin = CGPoint(x: bounds.midX - side / 2,
                             y: bounds.midY - side / 2 + bounds.height * 0.03)
        let radius = max(1, Self.pitch * scale * 0.34)

        let base = Self.dotColor
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (p, weight) in Self.dots {
            // The mark's y axis points down (SVG); AppKit's points up.
            let x = origin.x + p.x * scale
            let y = origin.y + (100 - p.y) * scale
            ctx.setFillColor(base.withAlphaComponent(base.alphaComponent * weight).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                       width: radius * 2, height: radius * 2))
        }
    }
}
