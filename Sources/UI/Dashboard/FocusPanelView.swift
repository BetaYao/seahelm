import AppKit

final class FocusPanelView: NSView {
    let terminalContainer = NSView()
    var isKeyboardFocused: Bool = false { didSet { updateKeyboardFocusAppearance() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setCornerMask(_ maskedCorners: CACornerMask, radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.maskedCorners = maskedCorners
        layer?.masksToBounds = true
    }

    private func updateKeyboardFocusAppearance() {
        if isKeyboardFocused {
            layer?.borderColor = SemanticColors.accent.cgColor
            layer?.borderWidth = 3
            layer?.shadowColor = SemanticColors.accent.cgColor
            layer?.shadowOpacity = 0.6
            layer?.shadowRadius = 10
            layer?.shadowOffset = .zero
            layer?.masksToBounds = false
        } else {
            layer?.borderColor = nil
            layer?.borderWidth = 1
            layer?.masksToBounds = true
            layer?.shadowOpacity = 0
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        setAccessibilityIdentifier("dashboard.focusPanel")
        setupTerminalContainer()
    }

    private func setupTerminalContainer() {
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalContainer)
        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Dim overlay

    private var dimOverlayLayer: CALayer?

    func showDimOverlay(opacity: CGFloat) {
        if dimOverlayLayer == nil {
            let overlay = CALayer()
            overlay.backgroundColor = NSColor.white.withAlphaComponent(opacity).cgColor
            overlay.frame = bounds
            overlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(overlay)
            dimOverlayLayer = overlay
        }
    }

    func hideDimOverlay() {
        dimOverlayLayer?.removeFromSuperlayer()
        dimOverlayLayer = nil
    }

    // MARK: - Focus restore

    /// Clicking anywhere on the focus panel (border, padding) should restore
    /// keyboard focus to the terminal inside.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Walk subviews to find the active split container and ask it to restore focus.
        if let split = terminalContainer.subviews.first(where: { $0 is SplitContainerView }) as? SplitContainerView {
            split.restoreFocusToActiveLeaf()
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func applyColors() {
        layer?.borderColor = resolvedCGColor(SemanticColors.lineAlpha70)
        layer?.backgroundColor = resolvedCGColor(SemanticColors.tileBg)
    }
}
