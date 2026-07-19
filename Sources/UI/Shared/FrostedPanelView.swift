import AppKit

/// System frosted-glass panel (menu / popover material). Use for command menus
/// and immersive input chrome so light and dark both track macOS vibrancy
/// instead of hand-tuned opaque fills.
final class FrostedPanelView: NSVisualEffectView {
    enum Kind {
        /// Floating autocomplete / completion list.
        case menu
        /// Inline input bar sitting on glass chrome.
        case input
    }

    var kind: Kind = .menu {
        didSet { applyAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.masksToBounds = true
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func applyAppearance() {
        // Match InlineWorktreeCreateView's completion panel and macOS menus:
        // `.menu` in both appearances — system resolves the correct light/dark glass.
        material = .menu
        switch kind {
        case .menu:
            layer?.cornerRadius = 10
            layer?.borderWidth = 0.5
            layer?.borderColor = resolvedCGColor(NSColor.separatorColor.withAlphaComponent(0.55))
        case .input:
            layer?.cornerRadius = 8
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }
}
