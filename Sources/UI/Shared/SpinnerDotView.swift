import AppKit

/// A small spinning 3/4-arc used as the `running` status dot in the dashboard.
///
/// The dashboard rebuilds every worktree row from scratch on each refresh
/// (`render()` tears down `stack.arrangedSubviews`), so a naive rotation would
/// restart from 0° on every rebuild and visibly jitter. We anchor the animation
/// to the layer's *absolute* time origin (`beginTime = convertTime(0, from: nil)`),
/// so a freshly created spinner resumes at the current phase — recreations are
/// seamless and every running dot on screen spins in lock-step.
final class SpinnerDotView: NSView {
    /// Visual diameter, matched to the weight of the 8pt glyph it replaces.
    private static let diameter: CGFloat = 9
    private static let lineWidth: CGFloat = 1.5
    private static let spinDuration: CFTimeInterval = 1.0
    private static let animationKey = "seahelm.spin"

    /// Appearance-aware stroke colour (resolved per effective appearance).
    private let color: NSColor
    private let arc = CAShapeLayer()

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        arc.fillColor = nil
        arc.lineWidth = Self.lineWidth
        arc.lineCap = .round
        layer?.addSublayer(arc)
        applyStrokeColor()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter, height: Self.diameter)
    }

    override func layout() {
        super.layout()
        // Centred arc, inset by half the stroke so it isn't clipped.
        let inset = Self.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        // 3/4 sweep (270°), leaving a gap that reads as motion when spun.
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) / 2,
                    startAngle: 0, endAngle: 1.5 * .pi, clockwise: false)
        arc.path = path
        arc.frame = layer?.bounds ?? bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are stripped when a layer leaves the window; (re)install
        // whenever we're attached and motion is allowed.
        if window != nil { installSpin() } else { arc.removeAnimation(forKey: Self.animationKey) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStrokeColor()
    }

    private func applyStrokeColor() {
        arc.strokeColor = color.resolvedCGColor(for: effectiveAppearance)
    }

    private func installSpin() {
        guard arc.animation(forKey: Self.animationKey) == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * CGFloat.pi          // clockwise (flipped layer coords)
        spin.duration = Self.spinDuration
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        // Anchor to absolute t=0 so phase is shared across all spinners and
        // survives row rebuilds without snapping back to 0°.
        spin.beginTime = arc.convertTime(0, from: nil)
        arc.add(spin, forKey: Self.animationKey)
    }
}

private extension NSColor {
    /// Resolve a dynamic `NSColor` to a concrete `CGColor` under `appearance`.
    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var cg = cgColor
        appearance.performAsCurrentDrawingAppearance {
            cg = self.cgColor
        }
        return cg
    }
}
