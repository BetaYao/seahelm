import AppKit

/// Layer-backed view whose background CGColor is re-resolved on every
/// light/dark switch. Use as a view-controller root (or any container) instead
/// of setting `someDynamicColor.cgColor` directly — a raw `.cgColor` snapshots
/// the color at resolve time and will not adapt when the appearance changes.
final class ThemedBackgroundView: NSView {
    /// The dynamic color to paint as the background. Defaults to the panel
    /// background; assign before the first layout if a different token is needed.
    var backgroundToken: NSColor = Theme.background {
        didSet { needsDisplay = true }
    }

    /// Optional hook fired after each effective-appearance change, so owners can
    /// re-resolve CGColors on child views they manage (dividers, borders, …).
    var onAppearanceChange: (() -> Void)?

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateLayer() {
        layer?.backgroundColor = resolvedCGColor(backgroundToken)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }
}
