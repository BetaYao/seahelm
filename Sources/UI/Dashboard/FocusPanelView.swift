import AppKit

final class FocusPanelView: NSView {
    let terminalContainer = NSView()
    var isKeyboardFocused: Bool = false { didSet { updateKeyboardFocusAppearance() } }

    /// Shadow lives on a dedicated borderless underlay (with an explicit
    /// shadowPath — no per-frame offscreen shape derivation), so the content can
    /// stay corner-clipped while focused. Toggling `masksToBounds` off for the
    /// glow used to let the terminal bleed past the rounded corners.
    private let glowLayer = CALayer()
    private var cornerRadius: CGFloat = 0
    private var maskedCorners: CACornerMask = [
        .layerMinXMinYCorner, .layerMaxXMinYCorner,
        .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setCornerMask(_ maskedCorners: CACornerMask, radius: CGFloat) {
        self.maskedCorners = maskedCorners
        cornerRadius = radius
        terminalContainer.layer?.cornerRadius = radius
        terminalContainer.layer?.maskedCorners = maskedCorners
        updateGlowPath()
    }

    private func updateKeyboardFocusAppearance() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            if isKeyboardFocused {
                terminalContainer.layer?.borderColor = SemanticColors.accent.cgColor
                terminalContainer.layer?.borderWidth = 3
                glowLayer.shadowOpacity = 0.6
            } else {
                // No card chrome: the centre panel is flush and border-less. The
                // accent border above is kept only as the keyboard-focus indicator.
                terminalContainer.layer?.borderColor = nil
                terminalContainer.layer?.borderWidth = 0
                glowLayer.shadowOpacity = 0
            }
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        glowLayer.shadowColor = SemanticColors.accent.cgColor
        glowLayer.shadowOpacity = 0
        glowLayer.shadowRadius = 10
        glowLayer.shadowOffset = .zero
        glowLayer.zPosition = -1
        layer?.addSublayer(glowLayer)

        setAccessibilityIdentifier("dashboard.focusPanel")
        setupTerminalContainer()
    }

    private func setupTerminalContainer() {
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.cornerCurve = .continuous
        terminalContainer.layer?.masksToBounds = true
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalContainer)
        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        updateGlowPath()
    }

    private func updateGlowPath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.frame = bounds
        glowLayer.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        )
        CATransaction.commit()
    }

    // MARK: - Dim overlay

    private var dimOverlayLayer: CALayer?

    func showDimOverlay(opacity: CGFloat) {
        let target = NSColor.white.withAlphaComponent(opacity).cgColor
        if let overlay = dimOverlayLayer {
            overlay.backgroundColor = target
            return
        }
        let overlay = CALayer()
        overlay.backgroundColor = target
        overlay.frame = terminalContainer.bounds
        overlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        overlay.opacity = 0
        // Inside the clipped container so the wash respects the rounded corners.
        terminalContainer.layer?.addSublayer(overlay)
        dimOverlayLayer = overlay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        overlay.add(fade, forKey: "fadeIn")
        overlay.opacity = 1
    }

    func hideDimOverlay() {
        guard let overlay = dimOverlayLayer else { return }
        dimOverlayLayer = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { overlay.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.12
        overlay.add(fade, forKey: "fadeOut")
        overlay.opacity = 0
        CATransaction.commit()
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
        // Clear so chrome glass + Ghostty fill read as one surface (no tile seam
        // under the terminal header).
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}
