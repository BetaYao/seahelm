import AppKit
import QuartzCore

/// A 2pt progress bar drawn across the top edge of a pane, driven by OSC 9;4.
///
/// Deliberately layer-only and non-interactive: it sits above a Metal surface, so
/// it must never take part in hit testing (a click near the top of a pane has to
/// reach the terminal) and must not force a redraw of the surface underneath.
final class PaneProgressBar: NSView {

    static let barHeight: CGFloat = 2

    private let track = CALayer()
    private let fill = CALayer()
    private var progress: OSCProgress?

    /// Fraction currently drawn, so `layout()` can re-apply it on resize without
    /// the caller re-sending the same report.
    private var drawnFraction: Double = 0

    private static let indeterminateAnimationKey = "seahelm.progress.indeterminate"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        track.addSublayer(fill)
        layer?.addSublayer(track)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Never intercept clicks — the terminal owns this strip of pixels.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    /// Apply a decoded report; nil (or a `remove` state) hides the bar.
    func update(_ progress: OSCProgress?) {
        guard progress != self.progress else { return }
        self.progress = progress

        guard let progress, progress.isActive else {
            stopIndeterminate()
            isHidden = true
            return
        }

        isHidden = false
        // Colors follow the status palette so a failing command reads the same
        // here as it does on the pane's status dot.
        let color: NSColor
        switch progress.state {
        case .error:   color = AgentStatus.error.color
        case .pause:   color = AgentStatus.waiting.color
        default:       color = AgentStatus.running.color
        }

        // Progress updates arrive per-chunk from the running command; implicit
        // layer animation would smear them into a lagging blur.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color.cgColor
        track.backgroundColor = color.withAlphaComponent(0.18).cgColor
        if let fraction = progress.fraction {
            stopIndeterminate()
            drawnFraction = max(0, min(1, fraction))
            applyFrames()
        } else {
            drawnFraction = 1
            applyFrames()
            startIndeterminate()
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFrames()
        CATransaction.commit()
        // The sweep's travel distance is a function of width.
        if progress?.fraction == nil, progress?.isActive == true { startIndeterminate() }
    }

    private func applyFrames() {
        track.frame = bounds
        let indeterminate = progress?.fraction == nil
        // The indeterminate sweep is a short segment that travels; a determinate
        // fill is anchored at the leading edge.
        let width = indeterminate ? bounds.width * 0.3 : bounds.width * CGFloat(drawnFraction)
        fill.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
    }

    // MARK: - Indeterminate sweep

    /// Reduce Motion turns the sweep into a static half-width bar — the pane
    /// still reads as "busy" without a looping animation.
    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func startIndeterminate() {
        stopIndeterminate()
        guard bounds.width > 0 else { return }
        guard !prefersReducedMotion else {
            fill.frame = CGRect(x: (bounds.width - fill.frame.width) / 2, y: 0,
                                width: fill.frame.width, height: bounds.height)
            return
        }
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = -fill.frame.width / 2
        travel.toValue = bounds.width + fill.frame.width / 2
        travel.duration = 1.1
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(travel, forKey: Self.indeterminateAnimationKey)
    }

    private func stopIndeterminate() {
        fill.removeAnimation(forKey: Self.indeterminateAnimationKey)
    }
}
