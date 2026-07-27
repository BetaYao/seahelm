import AppKit

/// Shared palette + controls for the onboarding wizard.
///
/// Everything here resolves through `SemanticColors`, so the wizard wears the
/// same skin as the app and re-themes live when the user picks an appearance in
/// step 3. (The old wizard was a fixed white design, which made picking "Dark"
/// feel like it hadn't done anything.)
enum OnboardingStyle {
    static var accent: NSColor { SemanticColors.accent }
    static var background: NSColor { Theme.background }
    static var panel: NSColor { SemanticColors.panel }
    static var panelHover: NSColor { SemanticColors.cardBgHover }
    static var panelSelected: NSColor { SemanticColors.cardBgSelected }
    static var stroke: NSColor { SemanticColors.lineAlpha22 }
    static var strokeSelected: NSColor { SemanticColors.cardBorderSelected }
    static var textPrimary: NSColor { SemanticColors.text }
    static var textSecondary: NSColor { SemanticColors.muted }
    static var textFaint: NSColor { SemanticColors.mutedAlpha50 }
    static var ok: NSColor { SemanticColors.running }
    static var warn: NSColor { SemanticColors.attention }

    /// Readable ink for text/glyphs sitting on a solid accent fill. Dark mode's
    /// accent is a bright cyan (white on it fails contrast), light mode's is deep
    /// teal (black on it fails), so pick by the resolved luminance.
    static func inkOnAccent(for appearance: NSAppearance) -> NSColor {
        appearance.isDark ? NSColor(hex: 0x03181e) : .white
    }

    static let cornerRadius: CGFloat = 10

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = textPrimary) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func monoLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                          color: NSColor = textSecondary) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = AppFont.mono(size: size, weight: weight)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func wrappingLabel(_ text: String, size: CGFloat,
                              color: NSColor = textSecondary) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: size)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// Small all-caps mono eyebrow — the wizard's section marker.
    static func eyebrow(_ text: String, color: NSColor = textFaint) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: AppFont.mono(size: 11, weight: .medium),
            .foregroundColor: color,
            .kern: 1.4,
        ])
    }
}

extension NSImage {
    /// Flat-tinted copy — SF Symbols embedded as text attachments ignore the
    /// button's `contentTintColor`, so they must be baked to the right color.
    func onboardingTinted(with color: NSColor) -> NSImage {
        let copy = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        copy.isTemplate = false
        return copy
    }
}

/// Views that need to repaint when the effective appearance flips. AppKit only
/// re-resolves dynamic `NSColor`s automatically for things it draws itself; our
/// layer-backed panels cache `CGColor`s and must be told.
protocol OnboardingThemeReactive: NSView {
    func applyTheme()
}

extension NSView {
    /// Walk the subtree and re-apply theme colors after an appearance change.
    func onboardingApplyThemeRecursively() {
        (self as? OnboardingThemeReactive)?.applyTheme()
        for sub in subviews { sub.onboardingApplyThemeRecursively() }
    }
}

/// Flat rounded card with optional hover/selected states and an optional
/// corner check badge shown while selected.
final class OnboardingPanel: NSView, OnboardingThemeReactive {
    var isSelected = false { didSet { applyTheme() } }
    var onClick: (() -> Void)?
    /// When true, a filled accent check circle appears top-right on selection.
    var showsCheckBadge = false {
        didSet { badge.isHidden = !(showsCheckBadge && isSelected) }
    }
    /// Selected cards get a soft accent halo. Off for large static containers,
    /// where the glow reads as a rendering artifact rather than a selection.
    var showsSelectionGlow = true

    private var hovering = false
    private var trackingArea: NSTrackingArea?
    private let badge = OnboardingCheckBadge()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OnboardingStyle.cornerRadius
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }
    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func layout() {
        super.layout()
        // Content subviews are added after init; keep the badge on top of them.
        if subviews.last !== badge {
            addSubview(badge, positioned: .above, relativeTo: nil)
        }
    }

    func applyTheme() {
        let bg: NSColor = isSelected
            ? OnboardingStyle.panelSelected
            : (hovering && onClick != nil ? OnboardingStyle.panelHover : OnboardingStyle.panel)
        layer?.backgroundColor = resolvedCGColor(bg)
        layer?.borderColor = resolvedCGColor(
            isSelected ? OnboardingStyle.strokeSelected
                : (hovering && onClick != nil ? SemanticColors.cardBorderHover : OnboardingStyle.stroke)
        )
        layer?.borderWidth = isSelected ? 1.5 : 1
        if isSelected && showsSelectionGlow {
            layer?.shadowColor = resolvedCGColor(OnboardingStyle.accent)
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 10
            layer?.shadowOffset = .zero
        } else {
            layer?.shadowOpacity = 0
        }
        badge.isHidden = !(showsCheckBadge && isSelected)
    }
}

/// Filled accent circle with a checkmark.
final class OnboardingCheckBadge: NSView, OnboardingThemeReactive {
    private let check = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 9
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true

        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(equalTo: centerXAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        layer?.backgroundColor = resolvedCGColor(OnboardingStyle.accent)
        check.contentTintColor = OnboardingStyle.inkOnAccent(for: effectiveAppearance)
    }
}

/// Accent-filled pill primary button with an optional ⌘↩ keycap chip.
final class OnboardingPrimaryButton: NSButton, OnboardingThemeReactive {
    private var hovering = false
    /// Extra trailing room for the keycap chip drawn into the title.
    var showsShortcut = true { didSet { applyTheme() } }
    /// Label text. Kept separate from `title` because setting attributedTitle
    /// writes the full string (keycap included) back into `title`.
    var text = "" { didSet { applyTheme() } }
    var fontSize: CGFloat = 13.5 { didSet { applyTheme() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let ink = OnboardingStyle.inkOnAccent(for: effectiveAppearance)
        let fill = isEnabled
            ? OnboardingStyle.accent.withAlphaComponent(hovering ? 0.85 : 1)
            : OnboardingStyle.accent.withAlphaComponent(0.35)
        layer?.backgroundColor = resolvedCGColor(fill)
        let composed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: ink,
        ])
        if showsShortcut {
            composed.append(NSAttributedString(string: "   ⌘↩", attributes: [
                .font: AppFont.mono(size: fontSize - 2, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.55),
            ]))
        }
        attributedTitle = composed
    }
}

/// Flat bordered button — the wizard's stand-in for `NSButton(bezelStyle:.rounded)`,
/// whose stock chrome fought the custom cards in the previous design.
final class OnboardingSecondaryButton: NSButton, OnboardingThemeReactive {
    private var hovering = false
    var text = "" { didSet { applyTheme() } }
    /// Optional leading SF Symbol drawn into the title.
    var symbol: String?

    init(text: String, symbol: String? = nil) {
        self.symbol = symbol
        super.init(frame: .zero)
        self.text = text
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { applyTheme() } }

    /// Borderless buttons hug their title exactly; add the padding the bezel
    /// would otherwise have supplied.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 24
        size.height = 30
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        layer?.backgroundColor = resolvedCGColor(
            hovering && isEnabled ? SemanticColors.panel2 : NSColor.clear
        )
        layer?.borderColor = resolvedCGColor(
            (hovering && isEnabled ? SemanticColors.cardBorderHover : OnboardingStyle.stroke)
                .withAlphaComponent(alpha)
        )
        let ink = OnboardingStyle.textPrimary.withAlphaComponent(alpha)
        let composed = NSMutableAttributedString()
        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 11, weight: .medium, scale: .small))?
               .onboardingTinted(with: ink) {
            let attachment = NSTextAttachment()
            attachment.image = image
            composed.append(NSAttributedString(attachment: attachment))
            composed.append(NSAttributedString(string: " "))
        }
        composed.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: ink,
        ]))
        attributedTitle = composed
    }
}

/// Borderless link-style button in the accent color.
final class OnboardingLinkButton: NSButton, OnboardingThemeReactive {
    var text: String { didSet { applyTheme() } }
    private let size: CGFloat

    init(title: String, size: CGFloat = 12.5) {
        self.text = title
        self.size = size
        super.init(frame: .zero)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: OnboardingStyle.accent,
        ])
    }
}

/// Rounded tile holding an SF Symbol, tinted by `tint`.
final class OnboardingIconTile: NSView, OnboardingThemeReactive {
    private let image = NSImageView()
    private let tint: () -> NSColor

    init(symbol: String, side: CGFloat = 34, pointSize: CGFloat = 15,
         tint: @escaping () -> NSColor = { OnboardingStyle.accent }) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbol: String, pointSize: CGFloat = 15) {
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let color = tint()
        layer?.backgroundColor = resolvedCGColor(color.withAlphaComponent(0.14))
        image.contentTintColor = color
    }
}

/// Small dot + label chip reporting the live state of a permission or install.
final class OnboardingStatusPill: NSView, OnboardingThemeReactive {
    enum State {
        case ok(String)
        case pending(String)
        case failed(String)

        var text: String {
            switch self {
            case .ok(let t), .pending(let t), .failed(let t): return t
            }
        }

        var color: NSColor {
            switch self {
            case .ok: return OnboardingStyle.ok
            case .pending: return OnboardingStyle.warn
            case .failed: return SemanticColors.danger
            }
        }
    }

    var state: State = .pending("Checking…") { didSet { applyTheme() } }

    private let dot = NSView()
    private let label = OnboardingStyle.label("", size: 11.5, weight: .medium)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 9),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let color = state.color
        label.stringValue = state.text
        label.textColor = color
        dot.layer?.backgroundColor = resolvedCGColor(color)
        layer?.backgroundColor = resolvedCGColor(color.withAlphaComponent(0.12))
    }
}

/// A pill toggle row: title + subtitle on the left, switch on the right.
final class OnboardingToggleRow: NSView {
    let toggle = NSSwitch()
    private let panel = OnboardingPanel()

    var isOn: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off }
    }

    init(title: String, subtitle: String, symbol: String, tint: @escaping () -> NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        panel.showsSelectionGlow = false

        let icon = OnboardingIconTile(symbol: symbol, side: 30, pointSize: 13, tint: tint)
        let titleLabel = OnboardingStyle.label(title, size: 13, weight: .semibold)
        let subtitleLabel = OnboardingStyle.label(subtitle, size: 11.5,
                                                  color: OnboardingStyle.textSecondary)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .small

        addSubview(panel)
        for v in [icon, titleLabel, subtitleLabel, toggle] as [NSView] { panel.addSubview(v) }

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 56),

            icon.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 11),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            toggle.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Document view for scrollers, so short content hugs the top rather than the bottom.
final class OnboardingFlippedView: NSView {
    override var isFlipped: Bool { true }
}
