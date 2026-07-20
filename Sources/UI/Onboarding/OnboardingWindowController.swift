import AppKit

/// Shared palette + small controls for the onboarding wizard. Bright,
/// spacious card design: white surface, system type, and a deep-cyan
/// accent derived from the product's #1FC8DA.
enum OnboardingStyle {
    /// Deep cyan for strokes/text on white; the raw brand cyan is too light.
    static let accent = NSColor(red: 0x0c / 255, green: 0x9e / 255, blue: 0xb2 / 255, alpha: 1)
    static let accentTint = accent.withAlphaComponent(0.07)
    static let background = NSColor.white
    static let panel = NSColor.white
    static let panelHover = NSColor.black.withAlphaComponent(0.03)
    static let panelSelected = accentTint
    static let stroke = NSColor.black.withAlphaComponent(0.12)
    static let strokeSelected = accent
    static let textPrimary = NSColor.black.withAlphaComponent(0.88)
    static let textSecondary = NSColor.black.withAlphaComponent(0.52)
    static let textFaint = NSColor.black.withAlphaComponent(0.34)

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

    /// Style a checkbox/button title without replacing the control.
    static func systemTitle(_ button: NSButton, size: CGFloat, weight: NSFont.Weight = .regular,
                            color: NSColor = textPrimary) {
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        )
    }
}

/// Flat rounded card with optional hover/selected states and an optional
/// corner check badge shown while selected.
final class OnboardingPanel: NSView {
    var isSelected = false { didSet { refresh() } }
    var onClick: (() -> Void)?
    /// When true, a filled accent check circle appears top-right on selection.
    var showsCheckBadge = false {
        didSet { badge.isHidden = !(showsCheckBadge && isSelected) }
    }
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    private let badge = OnboardingCheckBadge()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        refresh()
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

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func layout() {
        super.layout()
        // Content subviews are added after init; keep the badge on top of them.
        if subviews.last !== badge {
            addSubview(badge, positioned: .above, relativeTo: nil)
        }
    }

    private func refresh() {
        let bg: NSColor = isSelected
            ? OnboardingStyle.panelSelected
            : (hovering && onClick != nil ? OnboardingStyle.panelHover : OnboardingStyle.panel)
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = (isSelected ? OnboardingStyle.strokeSelected : OnboardingStyle.stroke).cgColor
        layer?.borderWidth = isSelected ? 1.5 : 1
        badge.isHidden = !(showsCheckBadge && isSelected)
    }
}

/// Filled accent circle with a white checkmark.
final class OnboardingCheckBadge: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = OnboardingStyle.accent.cgColor
        layer?.cornerRadius = 10
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        check.contentTintColor = .white
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(equalTo: centerXAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Near-black pill primary button with an embedded ⌘↩ keycap chip.
final class OnboardingPrimaryButton: NSButton {
    private var hovering = false
    /// Extra trailing room for the keycap chip drawn into the title.
    var showsShortcut = true { didSet { refresh() } }
    /// Label text. Kept separate from `title` because setting attributedTitle
    /// writes the full string (keycap included) back into `title`.
    var text = "" { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        refresh()
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

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func refresh() {
        layer?.backgroundColor = NSColor.black
            .withAlphaComponent(hovering ? 0.75 : 0.9).cgColor
        let composed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        if showsShortcut {
            composed.append(NSAttributedString(string: "   ⌘↩", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            ]))
        }
        attributedTitle = composed
    }
}

/// Borderless link-style button in the accent color.
final class OnboardingLinkButton: NSButton {
    init(title: String, color: NSColor = OnboardingStyle.textSecondary, size: CGFloat = 13) {
        super.init(frame: .zero)
        isBordered = false
        self.title = title
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Modal first-launch wizard. Completing it writes config and invokes `onComplete`.
final class OnboardingWindowController: NSWindowController {
    var onComplete: ((Config) -> Void)?

    private var config: Config
    private let contentVC: OnboardingViewController

    static let windowSize = NSSize(width: 880, height: 700)

    init(config: Config) {
        self.config = config
        self.contentVC = OnboardingViewController(config: config)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Seahelm"
        // Branded chrome: the wizard is part of the product, not a system sheet.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // The wizard is a fixed bright design; the in-app theme choice only
        // affects the app itself (previews show the difference).
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = OnboardingStyle.background
        window.isReleasedWhenClosed = false
        window.contentViewController = contentVC
        super.init(window: window)
        window.center()
        contentVC.onFinished = { [weak self] updated in
            guard let self else { return }
            self.config = updated
            self.onComplete?(updated)
            self.close()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Render each step to `<dir>/onboarding-step<N>.png` without showing a
    /// window — design iteration on headless/locked machines.
    static func renderSnapshots(to dir: String) {
        let vc = OnboardingViewController(config: Config.load())
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = vc
        for i in 0..<3 {
            vc.debugShowStep(i)
            // Let deferred main-queue work (scroll-to-top, layout passes) land.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            vc.view.layoutSubtreeIfNeeded()
            guard let rep = vc.view.bitmapImageRepForCachingDisplay(in: vc.view.bounds) else { continue }
            vc.view.cacheDisplay(in: vc.view.bounds, to: rep)
            let url = URL(fileURLWithPath: "\(dir)/onboarding-step\(i + 1).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
